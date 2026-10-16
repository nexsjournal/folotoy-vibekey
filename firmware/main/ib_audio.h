// main/ib_audio.h: 音频:麦克风上行(16 kHz IMA ADPCM)与本地合成提示音。
//
// codec 固定 16 kHz / 16 bit / 单声道,按引用计数开关:麦克风或提示音都不用时关闭以省电。
#pragma once

#include "esp_err.h"
#include "ib_link.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    IB_SOUND_START = 0,     // 上行双音 880 → 1320 Hz,各 40 ms
    IB_SOUND_STOP,          // 下行双音 1320 → 880 Hz
    IB_SOUND_DONE,          // 短促一声
    IB_SOUND_AGENT_DONE,    // Agent 完成:上行三音 C6 → E6 → G6
    IB_SOUND_AGENT_INPUT,   // Agent 等你:两声短促 E6 + 一声 A6
} ib_sound_t;

// 麦克风帧发送回调,运行在麦克风任务里;frame 已含二进制帧头。
// USB:每帧 2 块(40 ms,334 字节);BLE:每帧 1 块(20 ms,170 字节)。
typedef void (*ib_audio_tx_cb_t)(ib_link_t link, const uint8_t *frame, size_t len);

esp_err_t ib_audio_init(ib_audio_tx_cb_t tx);

// 以下控制函数只在 ib_app 任务中调用。
esp_err_t ib_audio_mic_start(ib_link_t link);
void ib_audio_mic_stop(void);
bool ib_audio_mic_active(void);
ib_link_t ib_audio_mic_link(void);

// 异步播放提示音;正在播放时新的提示音替换排队中的那个。
void ib_audio_play(ib_sound_t sound);
