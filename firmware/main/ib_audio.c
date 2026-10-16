// main/ib_audio.c: 音频实现。
//
// 任务:
//   ib_mic  (prio 6):bsp_audio_read 20 ms → IMA ADPCM 块 → 二进制帧 → tx 回调
//   ib_tone (prio 6):从队列取提示音,逐块合成正弦并 bsp_audio_write
// 两个任务可同时运行(I2S 全双工,读写各用一个通道)。codec 的打开/关闭由引用计数串行化。
#include "ib_audio.h"

#include "bsp_audio.h"
#include "ib_adpcm.h"
#include "ib_protocol.h"

#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include <math.h>
#include <string.h>

static const char *TAG = "ib_audio";

#define SAMPLE_RATE      16000
#define TASK_PRIO        6
#define MIC_TASK_STACK   3072
#define TONE_TASK_STACK  2560
#define STOP_TIMEOUT_MS  1500       // 大于 I2S 读写超时
#define OUT_VOLUME       65         // codec 输出音量(%)
#define TONE_AMPLITUDE   9000       // 约 -11 dBFS
#define FADE_SAMPLES     64         // 4 ms 起落,避免爆音
#define TAIL_SILENCE_MS  120        // 等 DMA 里的尾巴播完再关 codec

#define BIT_MIC_IDLE  (1 << 0)

static bool s_ready;
static ib_audio_tx_cb_t s_tx;
static SemaphoreHandle_t s_lock;
static EventGroupHandle_t s_events;
static QueueHandle_t s_tone_queue;
static int s_codec_users;

static volatile bool s_mic_on;
static ib_link_t s_mic_link;
static TaskHandle_t s_mic_task;
static int16_t s_mic_pcm[IB_ADPCM_BLOCK_SAMPLES];
static uint8_t s_mic_frame[IB_BIN_HDR + 2 * IB_ADPCM_BLOCK_BYTES];

static int16_t s_sine[256];
static int16_t s_tone_pcm[IB_ADPCM_BLOCK_SAMPLES];

// ---------------------------------------------------------------------------
// codec 引用计数:0→1 打开,1→0 静音后关闭。调用方保证切换时没有任务在读写。
// ---------------------------------------------------------------------------

static esp_err_t codec_acquire(void)
{
    esp_err_t err = ESP_OK;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_codec_users == 0) {
        err = bsp_audio_set_format(SAMPLE_RATE, 16, 1);
        if (err == ESP_OK) {
            bsp_audio_set_volume(OUT_VOLUME);
            bsp_audio_mute(false);
        }
    }
    if (err == ESP_OK) s_codec_users++;
    xSemaphoreGive(s_lock);
    return err;
}

static void codec_release(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_codec_users > 0 && --s_codec_users == 0) {
        bsp_audio_mute(true);
        bsp_audio_close();
    }
    xSemaphoreGive(s_lock);
}

// ---------------------------------------------------------------------------
// 麦克风
// ---------------------------------------------------------------------------

static void mic_task(void *arg)
{
    (void)arg;
    ib_adpcm_state_t st;
    for (;;) {
        xEventGroupSetBits(s_events, BIT_MIC_IDLE);
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        xEventGroupClearBits(s_events, BIT_MIC_IDLE);

        ib_adpcm_init(&st);
        uint8_t seq = 0;
        // 丢掉 DMA 里的旧样本(约 60 ms),之后每块都是新鲜数据。
        for (int i = 0; i < 3 && s_mic_on; i++) bsp_audio_read(s_mic_pcm, sizeof(s_mic_pcm));
        int blocks = s_mic_link == IB_LINK_USB ? 2 : 1;
        while (s_mic_on) {
            int got = 0;
            while (got < blocks && s_mic_on) {
                if (bsp_audio_read(s_mic_pcm, sizeof(s_mic_pcm)) != ESP_OK) {
                    vTaskDelay(pdMS_TO_TICKS(20));
                    continue;
                }
                ib_adpcm_encode_block(&st, s_mic_pcm, s_mic_frame + IB_BIN_HDR + got * IB_ADPCM_BLOCK_BYTES);
                got++;
            }
            if (!s_mic_on) break;
            size_t payload = (size_t)blocks * IB_ADPCM_BLOCK_BYTES;
            ib_bin_header(s_mic_frame, IB_BIN_ADPCM, seq++, payload);
            if (s_tx) s_tx(s_mic_link, s_mic_frame, IB_BIN_HDR + payload);
        }
    }
}

esp_err_t ib_audio_mic_start(ib_link_t link)
{
    if (!s_ready) return ESP_ERR_INVALID_STATE;
    if (s_mic_on && s_mic_link == link) return ESP_OK;
    if (s_mic_on) ib_audio_mic_stop();
    ESP_RETURN_ON_ERROR(codec_acquire(), TAG, "codec open failed");
    s_mic_link = link;
    s_mic_on = true;
    xTaskNotifyGive(s_mic_task);
    return ESP_OK;
}

void ib_audio_mic_stop(void)
{
    if (!s_mic_on) return;
    s_mic_on = false;
    xEventGroupWaitBits(s_events, BIT_MIC_IDLE, pdFALSE, pdTRUE, pdMS_TO_TICKS(STOP_TIMEOUT_MS));
    codec_release();
}

bool ib_audio_mic_active(void)
{
    return s_mic_on;
}

ib_link_t ib_audio_mic_link(void)
{
    return s_mic_link;
}

// ---------------------------------------------------------------------------
// 提示音
// ---------------------------------------------------------------------------

typedef struct {
    uint16_t hz;
    uint16_t ms;
    bool decay;         // 指数衰减(短促的"叮")
} tone_seg_t;

static const tone_seg_t SOUND_START[] = { { 880, 40, false }, { 1320, 40, false } };
static const tone_seg_t SOUND_STOP[] = { { 1320, 40, false }, { 880, 40, false } };
static const tone_seg_t SOUND_DONE[] = { { 1568, 90, true } };
static const tone_seg_t SOUND_AGENT_DONE[] = { { 1047, 70, false }, { 1319, 70, false }, { 1568, 180, true } };
// hz 为 0 的段是静音间隔。
static const tone_seg_t SOUND_AGENT_INPUT[] = {
    { 1319, 70, false }, { 0, 60, false }, { 1319, 70, false }, { 0, 60, false }, { 1760, 160, true },
};

static void write_silence(int ms)
{
    memset(s_tone_pcm, 0, sizeof(s_tone_pcm));
    int samples = SAMPLE_RATE * ms / 1000;
    while (samples > 0) {
        int n = samples < IB_ADPCM_BLOCK_SAMPLES ? samples : IB_ADPCM_BLOCK_SAMPLES;
        bsp_audio_write(s_tone_pcm, (size_t)n * 2);
        samples -= n;
    }
}

static void play_segment(const tone_seg_t *seg)
{
    if (seg->hz == 0) {
        write_silence(seg->ms);
        return;
    }
    int total = SAMPLE_RATE * seg->ms / 1000;
    uint32_t phase = 0;
    uint32_t step = (uint32_t)(((uint64_t)seg->hz << 32) / SAMPLE_RATE);   // 32 位相位累加器
    int done = 0;
    while (done < total) {
        int n = total - done < IB_ADPCM_BLOCK_SAMPLES ? total - done : IB_ADPCM_BLOCK_SAMPLES;
        for (int i = 0; i < n; i++) {
            int idx = done + i;
            int32_t env = 256;                                  // Q8 包络
            if (idx < FADE_SAMPLES) env = idx * 256 / FADE_SAMPLES;
            int remain = total - idx;
            if (remain < FADE_SAMPLES) env = env * remain / FADE_SAMPLES;
            if (seg->decay) env = env * (total - idx) / total * (total - idx) / total;
            int32_t s = (int32_t)s_sine[phase >> 24] * TONE_AMPLITUDE / 32767;
            s_tone_pcm[i] = (int16_t)(s * env / 256);
            phase += step;
        }
        bsp_audio_write(s_tone_pcm, (size_t)n * 2);
        done += n;
    }
}

static void tone_task(void *arg)
{
    (void)arg;
    ib_sound_t sound;
    for (;;) {
        if (xQueueReceive(s_tone_queue, &sound, portMAX_DELAY) != pdTRUE) continue;
        if (codec_acquire() != ESP_OK) continue;
        write_silence(10);
        const tone_seg_t *segs;
        size_t count;
#define PICK(arr) do { segs = (arr); count = sizeof(arr) / sizeof((arr)[0]); } while (0)
        switch (sound) {
        case IB_SOUND_START: PICK(SOUND_START); break;
        case IB_SOUND_STOP: PICK(SOUND_STOP); break;
        case IB_SOUND_AGENT_DONE: PICK(SOUND_AGENT_DONE); break;
        case IB_SOUND_AGENT_INPUT: PICK(SOUND_AGENT_INPUT); break;
        default: PICK(SOUND_DONE); break;
        }
#undef PICK
        for (size_t i = 0; i < count; i++) play_segment(&segs[i]);
        write_silence(TAIL_SILENCE_MS);
        codec_release();
    }
}

void ib_audio_play(ib_sound_t sound)
{
    if (!s_ready) return;
    xQueueOverwrite(s_tone_queue, &sound);
}

esp_err_t ib_audio_init(ib_audio_tx_cb_t tx)
{
    s_tx = tx;
    ESP_RETURN_ON_ERROR(bsp_audio_init(), TAG, "bsp_audio_init failed");
    for (int i = 0; i < 256; i++) s_sine[i] = (int16_t)(32767.0f * sinf((float)i * 6.2831853f / 256.0f));

    s_lock = xSemaphoreCreateMutex();
    s_events = xEventGroupCreate();
    s_tone_queue = xQueueCreate(1, sizeof(ib_sound_t));
    ESP_RETURN_ON_FALSE(s_lock && s_events && s_tone_queue, ESP_ERR_NO_MEM, TAG, "alloc failed");
    BaseType_t ok = xTaskCreate(mic_task, "ib_mic", MIC_TASK_STACK, NULL, TASK_PRIO, &s_mic_task);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "mic task failed");
    ok = xTaskCreate(tone_task, "ib_tone", TONE_TASK_STACK, NULL, TASK_PRIO, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "tone task failed");
    bsp_audio_mute(true);
    s_ready = true;
    return ESP_OK;
}
