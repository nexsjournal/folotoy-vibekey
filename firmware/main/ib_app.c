// main/ib_app.c: InputBetter 应用核心(状态机)。
//
// 线程模型:
//   button 组件任务    ib_app_on_button()   只投递按键事件
//   USB 接收任务       on_usb_line()        解析命令后投递
//   NimBLE host 任务   on_ble_line/link()   解析命令或订阅变化后投递
//   ib_app 任务        app_task()           唯一消费者:发送协议消息、驱动 UI / 音频 / 背光、读电量
// 应用状态只在 ib_app 任务中读写,不需要额外的锁。麦克风帧由 ib_audio 的麦克风任务直接经 audio_tx() 发送。
//
// 时序要点:
//   - 15 s 没收到命令、bye、USB 拔线、BLE 断开 → 对应链路离线;两条都离线 → OFFLINE 时钟页并停麦克风。
//   - config.mic=1 时,在线、IDLE、非字幕模式下 OK 键按下的瞬间就开始推送麦克风(不等 mic 命令);
//     2 s 内 Mac 没切到 rec,或 Mac 下发 proc/done/err/sub(以及 600 ms 宽限期之后的 idle)就停止。
//   - done 页 1.2 s、err 页 2 s 后自行回到 IDLE 动画。
//   - Agent 通知:done 15 s 后自动关闭;input 每 20 s 重复提示音,直到按键或 clear。
//   - 列表页:收到 st=list 且收到过 list 命令才显示(两者先后不限);离开 list 状态后旧列表作废。
#include "ib_app.h"

#include "bsp_battery.h"
#include "bsp_display.h"
#include "ib_audio.h"
#include "ib_ble.h"
#include "ib_clock.h"
#include "ib_keys.h"
#include "ib_links.h"
#include "ib_protocol.h"
#include "ib_ui.h"
#include "ib_usb.h"

#include "esp_app_desc.h"
#include "esp_check.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#include <string.h>

static const char *TAG = "ib_app";

_Static_assert((int)BSP_BTN_UP == (int)IB_KEY_UP && (int)BSP_BTN_DOWN == (int)IB_KEY_DOWN &&
               (int)BSP_BTN_OK == (int)IB_KEY_OK, "bsp_btn_t and ib_key_t must share the same order");
_Static_assert((int)IB_UI_KEY_UP == (int)IB_KEY_UP && (int)IB_UI_KEY_DOWN == (int)IB_KEY_DOWN &&
               (int)IB_UI_KEY_OK == (int)IB_KEY_OK, "ib_ui_key_t and ib_key_t must share the same order");

#define EVENT_QUEUE_LEN      16
#define APP_TASK_STACK       4096
#define APP_TASK_PRIO        5
#define LOOP_PERIOD_MS       100
#define BATTERY_PERIOD_MS    60000
#define BACKLIGHT_ON         80
#define DEFAULT_SCREEN_OFF_S 60
#define DONE_HOLD_MS         1200
#define ERR_HOLD_MS          2000
#define MIC_LOCAL_GRACE_MS   600    // 本地开麦后这段时间内收到的 idle 不停麦(Mac 还没来得及切 rec)
#define MIC_LOCAL_WAIT_MS    2000   // 本地开麦后 Mac 迟迟不切 rec 就停麦
#define MIC_TAIL_MS          500    // 离开 rec 进入 proc 后继续推流的最长时间(Mac 要录完尾音,等它发 mic off)
#define AGENT_DONE_MS        15000
#define AGENT_CHIME_MS       20000

typedef enum {
    EV_KEY,
    EV_COMMAND,
    EV_BLE_LINK,
} ev_type_t;

typedef struct {
    ev_type_t type;
    ib_link_t link;         // EV_COMMAND
    ib_key_t key;           // EV_KEY
    ib_key_ev_t key_ev;     // EV_KEY
    bool subscribed;        // EV_BLE_LINK
    ib_cmd_t cmd;           // EV_COMMAND
} app_event_t;

static QueueHandle_t s_queue;
static bool s_ui_ok;
static bool s_battery_ok;
static bool s_audio_ok;
static uint32_t s_boot_id;
static char s_build_id[IB_BUILD_ID_LEN + 1];   // ELF SHA-256 前 8 位,hello 里上报
static uint32_t s_seq;

// 链路
static ib_links_t s_links;
static bool s_online;
static bool s_usb_present;
static bool s_ble_subscribed;
static int s_ui_link = -1;
static int s_ui_online = -1;

// Mac 下发的设置
static bool s_cfg_mic;
static bool s_cfg_sound = true;
static int64_t s_screen_off_ms = DEFAULT_SCREEN_OFF_S * 1000;

// Mac 下发的状态与当前显示
static ib_state_t s_st = IB_ST_IDLE;
static ib_mode_t s_mode = IB_MODE_DICT;
// 「常驻」页面:最近一次 idle / sub 状态的模式、页面和 msg。done / err 自动返回时回到这里,
// 而不是 rec / proc 带来的听写模式和默认空闲页(否则字幕模式或字幕运行时会短暂闪出错误的页面)。
static ib_mode_t s_home_mode = IB_MODE_DICT;
static ib_state_t s_home_st = IB_ST_IDLE;
static char s_home_msg[IB_TEXT_MAX];
static int64_t s_mic_tail_until;
static char s_msg[IB_TEXT_MAX];
static ib_ui_screen_t s_screen = IB_UI_OFFLINE;
static int64_t s_revert_at;             // done/err 自动回 IDLE 的时刻,0 表示无
static bool s_list_ready;               // 收到过当前这轮的 list 命令

// 按键
static ib_keys_t s_keys;

// 麦克风:本地(OK 键)开启时记下时刻,等待 Mac 切到 rec 确认
static bool s_mic_local;
static int64_t s_mic_local_ms;

// Agent 通知
static bool s_agent_on;
static ib_agent_ev_t s_agent_kind;
static int64_t s_agent_deadline;        // done 自动关闭时刻
static int64_t s_agent_next_chime;      // input 下次提醒时刻

// 背光
static bool s_backlight_on;
static int64_t s_last_activity_ms;

// 电量
static int s_soc = -1;
static int s_mv = -1;
static bool s_charging;
static int64_t s_last_battery_ms;

// 时钟:Mac 下发本地时间时记下当时的 esp_timer 读数,之后按流逝时间推算
static bool s_clock_valid;
static uint32_t s_clock_local;
static int64_t s_clock_synced_ms;
static int64_t s_clock_minute = -1;

static int64_t now_ms(void)
{
    return esp_timer_get_time() / 1000 + 1;     // +1:保证非 0(ib_links 用 0 表示离线)
}

// ---------------------------------------------------------------------------
// 事件生产者(其它任务):只投递,不阻塞。
// ---------------------------------------------------------------------------

void ib_app_on_button(bsp_btn_t btn, bsp_btn_ev_t ev, void *user)
{
    (void)user;
    if (!s_queue || (unsigned)btn >= IB_KEY_COUNT) return;
    app_event_t event = { .type = EV_KEY, .key = (ib_key_t)btn };
    switch (ev) {
    case BSP_BTN_PRESS: event.key_ev = IB_KEY_EV_DOWN; break;
    case BSP_BTN_RELEASE: event.key_ev = IB_KEY_EV_UP; break;
    case BSP_BTN_LONG: event.key_ev = IB_KEY_EV_LONG; break;
    default: return;
    }
    xQueueSend(s_queue, &event, 0);
}

static void post_command(ib_link_t link, const char *line, size_t len)
{
    app_event_t event = { .type = EV_COMMAND, .link = link };
    if (!ib_parse_command(line, len, &event.cmd)) return;     // 非法或未知命令整条丢弃
    xQueueSend(s_queue, &event, 0);
}

static void on_usb_line(const char *line, size_t len)
{
    post_command(IB_LINK_USB, line, len);
}

static void on_ble_line(const char *line, size_t len)
{
    post_command(IB_LINK_BLE, line, len);
}

static void on_ble_link(bool subscribed)
{
    app_event_t event = { .type = EV_BLE_LINK, .subscribed = subscribed };
    xQueueSend(s_queue, &event, 0);
}

// 麦克风帧发送,运行在麦克风任务里。
static void audio_tx(ib_link_t link, const uint8_t *frame, size_t len)
{
    if (link == IB_LINK_USB) {
        ib_usb_send_bin(frame, len);
    } else {
        ib_ble_send_audio(frame, len);
    }
}

// ---------------------------------------------------------------------------
// 以下只在 ib_app 任务中调用。
// ---------------------------------------------------------------------------

static void send_to(ib_link_t link, const char *msg, size_t len)
{
    if (len == 0) return;
    if (link == IB_LINK_USB) {
        ib_usb_send(msg, len);
    } else {
        ib_ble_send(msg, len);
    }
}

// 发给所有在线链路;Mac 用 (boot, seq) 对 key 事件去重。
static void send_alive(const char *msg, size_t len, int64_t now)
{
    for (int i = 0; i < IB_LINK_COUNT; i++) {
        if (ib_links_alive(&s_links, (ib_link_t)i, now)) send_to((ib_link_t)i, msg, len);
    }
}

static void set_backlight(bool on)
{
    if (on == s_backlight_on) return;
    s_backlight_on = on;
    if (!s_ui_ok) return;
    bsp_display_backlight(on ? BACKLIGHT_ON : 0);
    ib_ui_set_awake(on);
}

static void wake(int64_t now)
{
    s_last_activity_ms = now;
    set_backlight(true);
}

static void play(ib_sound_t sound)
{
    if (s_audio_ok && s_cfg_sound) ib_audio_play(sound);
}

static ib_ui_mode_t ui_mode(void)
{
    return s_mode == IB_MODE_TR ? IB_UI_MODE_TR : s_mode == IB_MODE_SUB ? IB_UI_MODE_SUB : IB_UI_MODE_DICT;
}

static void show_screen(ib_ui_screen_t screen)
{
    s_screen = screen;
    if (s_ui_ok) ib_ui_show(screen, ui_mode(), s_msg);
}

// ---- 麦克风 ----

static void mic_stop(void)
{
    s_mic_local = false;
    if (!s_audio_ok || !ib_audio_mic_active()) return;
    ib_audio_mic_stop();
    ib_ble_set_audio_mode(false);
}

static void mic_start(ib_link_t link, bool local, int64_t now)
{
    if (!s_audio_ok || ib_audio_mic_start(link) != ESP_OK) return;
    s_mic_local = local;
    s_mic_local_ms = now;
    ib_ble_set_audio_mode(link == IB_LINK_BLE);
}

// ---- Agent 通知 ----

static void agent_clear(void)
{
    if (!s_agent_on) return;
    s_agent_on = false;
    if (s_ui_ok) ib_ui_agent_hide();
}

static void agent_show(ib_agent_ev_t kind, const char *source, int64_t now)
{
    s_agent_on = true;
    s_agent_kind = kind;
    s_agent_deadline = now + AGENT_DONE_MS;
    s_agent_next_chime = now + AGENT_CHIME_MS;
    if (s_ui_ok) ib_ui_agent_show(kind == IB_AGENT_DONE ? IB_UI_AGENT_DONE : IB_UI_AGENT_INPUT, source);
    play(kind == IB_AGENT_DONE ? IB_SOUND_AGENT_DONE : IB_SOUND_AGENT_INPUT);
    wake(now);
}

// Agent 全屏通知层是否在接收按键(录音中只显示横幅,按键照常工作)。
static bool agent_capturing(void)
{
    return s_agent_on && s_screen != IB_UI_REC;
}

// ---- 时钟与电量 ----

static void refresh_clock(int64_t now, bool force)
{
    if (!s_ui_ok) return;
    if (!s_clock_valid) {
        if (force) ib_ui_set_clock("", "");
        return;
    }
    uint32_t local = s_clock_local + (uint32_t)((now - s_clock_synced_ms) / 1000);
    int64_t minute = local / 60;
    if (!force && minute == s_clock_minute) return;
    s_clock_minute = minute;
    char t[IB_CLOCK_TIME_LEN];
    char d[IB_CLOCK_DATE_LEN];
    ib_clock_format(local, t, d);
    ib_ui_set_clock(t, d);
}

static void send_battery(ib_link_t link)
{
    char msg[IB_MSG_MAX];
    send_to(link, msg, ib_format_battery(msg, sizeof(msg), s_soc, s_mv, s_charging));
}

static void refresh_battery(int64_t now, bool force)
{
    if (!force && now - s_last_battery_ms < BATTERY_PERIOD_MS) return;
    s_last_battery_ms = now;
    if (s_battery_ok) {
        // I2C 读取带 100 ms 超时,放在应用任务里不会阻塞按键回调。
        s_soc = bsp_battery_soc();
        s_mv = bsp_battery_mv();
    }
    // 板上没有充电状态引脚:插着 USB 主机且未充满即视为充电中(见 README 说明)。
    s_charging = s_usb_present && s_soc >= 0 && s_soc < 100;
    if (s_ui_ok) ib_ui_set_battery(s_soc, s_charging);
    for (int i = 0; i < IB_LINK_COUNT; i++) {
        if (ib_links_alive(&s_links, (ib_link_t)i, now)) send_battery((ib_link_t)i);
    }
}

// ---- 状态 ----

static ib_ui_screen_t screen_for(ib_state_t st)
{
    switch (st) {
    case IB_ST_REC: return IB_UI_REC;
    case IB_ST_PROC: return IB_UI_PROC;
    case IB_ST_DONE: return IB_UI_DONE;
    case IB_ST_ERR: return IB_UI_ERR;
    case IB_ST_SUB: return IB_UI_SUB;
    // 列表内容还没到时保持当前页面(离线页除外,回到 IDLE),等 list 命令到达再切换。
    case IB_ST_LIST: return s_list_ready ? IB_UI_LIST : (s_screen == IB_UI_OFFLINE ? IB_UI_IDLE : s_screen);
    default: return IB_UI_IDLE;
    }
}

static void apply_state(const ib_cmd_t *cmd, int64_t now)
{
    ib_state_t prev = s_st;
    s_st = cmd->state;
    if (prev == IB_ST_LIST && s_st != IB_ST_LIST) s_list_ready = false;
    if (cmd->has_mode) s_mode = cmd->mode;
    if (cmd->has_msg) {
        memcpy(s_msg, cmd->msg, sizeof(s_msg));
    } else {
        s_msg[0] = '\0';
    }
    if (s_st == IB_ST_IDLE || s_st == IB_ST_SUB) {
        s_home_mode = s_mode;
        s_home_st = s_st;
        memcpy(s_home_msg, s_msg, sizeof(s_home_msg));
    }

    // 提示音:进入录音上行双音;离开录音下行双音;完成短促一声。
    if (s_st == IB_ST_REC && prev != IB_ST_REC) play(IB_SOUND_START);
    if (s_st == IB_ST_DONE && prev != IB_ST_DONE) {
        play(IB_SOUND_DONE);
    } else if (prev == IB_ST_REC && s_st != IB_ST_REC) {
        play(IB_SOUND_STOP);
    }

    // 麦克风:rec 确认本地开麦;其它状态停麦。例外:
    // - 本地刚开麦时收到的 idle / sub 给一个宽限期(Mac 还没来得及切 rec);
    // - rec → proc 继续推流,等 Mac 的 mic off(它要录完 150 ms 尾音),最多 MIC_TAIL_MS。
    if (s_st == IB_ST_REC) {
        s_mic_local = false;
        s_mic_tail_until = 0;
    } else if (s_audio_ok && ib_audio_mic_active()) {
        bool grace = (s_st == IB_ST_IDLE || s_st == IB_ST_SUB) && s_mic_local && now - s_mic_local_ms < MIC_LOCAL_GRACE_MS;
        bool tail = s_st == IB_ST_PROC && prev == IB_ST_REC;
        if (tail) {
            s_mic_tail_until = now + MIC_TAIL_MS;
        } else if (!grace) {
            mic_stop();
        }
    }

    s_revert_at = s_st == IB_ST_DONE ? now + DONE_HOLD_MS : s_st == IB_ST_ERR ? now + ERR_HOLD_MS : 0;
    show_screen(screen_for(s_st));
    wake(now);
}

static void apply_list(const ib_cmd_t *cmd)
{
    ib_ui_list_t list;
    memset(&list, 0, sizeof(list));
    _Static_assert(IB_UI_LIST_ROWS == IB_LIST_ROWS, "list row count mismatch");
    _Static_assert(sizeof(list.title) == IB_TEXT_MAX && sizeof(list.items[0]) == IB_TEXT_MAX, "list text size");
    memcpy(list.title, cmd->list_title, sizeof(list.title));
    memcpy(list.items, cmd->list_item, sizeof(list.items));
    list.rows = cmd->list_rows;
    list.n = cmd->list_n;
    list.top = cmd->list_top;
    list.sel = cmd->list_sel;
    if (s_ui_ok) ib_ui_set_list(&list);
    s_list_ready = true;
    if (s_st == IB_ST_LIST && s_screen != IB_UI_LIST) show_screen(IB_UI_LIST);
}

// ---- 链路 ----

static void go_offline(void)
{
    mic_stop();
    agent_clear();
    ib_keys_reset(&s_keys);
    s_st = IB_ST_IDLE;
    s_msg[0] = '\0';
    s_revert_at = 0;
    s_list_ready = false;
    if (s_ui_ok) {
        ib_ui_set_ok_held(false);
        ib_ui_set_level(0);
    }
    show_screen(IB_UI_OFFLINE);
    refresh_clock(now_ms(), true);
}

static void refresh_links(int64_t now)
{
    bool usb = ib_usb_host_present();
    if (!usb) {
        // 拔线收不到 bye:物理连接消失立即清除 USB 链路;Mac 此刻开始扫 BLE,切快速广播。
        ib_links_drop(&s_links, IB_LINK_USB);
        if (s_usb_present) ib_ble_boost_advertising();
    }
    if (usb != s_usb_present) {
        s_usb_present = usb;
        refresh_battery(now, true);     // 更新充电图标
    }

    bool online = ib_links_any(&s_links, now);
    if (online != s_online) {
        s_online = online;
        if (online) {
            show_screen(screen_for(s_st));
        } else {
            go_offline();
        }
        wake(now);
    }

    // 麦克风所在链路断开时停止。
    if (s_audio_ok && ib_audio_mic_active() && !ib_links_alive(&s_links, ib_audio_mic_link(), now)) mic_stop();

    ib_link_t pref = ib_links_preferred(&s_links, now);
    ib_ui_link_t ui_link;
    if (pref == IB_LINK_USB || (pref == IB_LINK_COUNT && usb)) {
        ui_link = IB_UI_LINK_USB;
    } else if (pref == IB_LINK_BLE || s_ble_subscribed) {
        ui_link = IB_UI_LINK_BLE;
    } else {
        ui_link = IB_UI_LINK_NONE;
    }
    if ((int)ui_link != s_ui_link || (int)online != s_ui_online) {
        s_ui_link = (int)ui_link;
        s_ui_online = (int)online;
        if (s_ui_ok) ib_ui_set_link(ui_link, online);
    }
}

// ---- 事件处理 ----

static void handle_key(ib_key_t key, ib_key_ev_t ev, int64_t now)
{
    bool dark = !s_backlight_on;
    if (ev == IB_KEY_EV_DOWN) {
        wake(now);
        if (s_ui_ok && !dark) ib_ui_key_press((ib_ui_key_t)key);
    }
    ib_key_action_t act = ib_keys_handle(&s_keys, key, ev, now, s_online, dark, agent_capturing());
    if (act.dismiss_agent) agent_clear();
    if (act.send) {
        char msg[IB_MSG_MAX];
        send_alive(msg, ib_format_key(msg, sizeof(msg), key, ev, act.ack, ++s_seq, s_boot_id), now);
    }
    if (key != IB_KEY_OK) return;

    // 以屏幕为准判断"空闲":done/err 自行回到常驻页后 Mac 的状态可能还没到,此时按 OK 也应立即开麦。
    // 字幕在运行时(听写 / 翻译模式)显示的是字幕页,OK 同样是说话。
    if (ev == IB_KEY_EV_DOWN && act.send && !act.ack && s_cfg_mic &&
        (s_screen == IB_UI_IDLE || s_screen == IB_UI_SUB) &&
        s_mode != IB_MODE_SUB && s_audio_ok && !ib_audio_mic_active()) {
        // Passport 麦克风作为听写音源:按下瞬间就开始推流,不等 Mac 的 mic 命令,减少首字丢失。
        ib_link_t link = ib_links_preferred(&s_links, now);
        if (link != IB_LINK_COUNT) mic_start(link, true, now);
    }
    if (s_ui_ok && ev != IB_KEY_EV_LONG) ib_ui_set_ok_held(ev == IB_KEY_EV_DOWN && act.send);
}

static void handle_command(ib_link_t link, const ib_cmd_t *cmd, int64_t now)
{
    char msg[IB_MSG_MAX];
    if (cmd->type == IB_CMD_BYE) {
        ib_links_drop(&s_links, link);
        refresh_links(now);
        return;
    }
    ib_links_seen(&s_links, link, now);
    refresh_links(now);         // 可能刚变为在线

    switch (cmd->type) {
    case IB_CMD_HELLO:
        send_to(link, msg,
                ib_format_hello(msg, sizeof(msg), esp_app_get_description()->version, s_build_id, s_boot_id));
        send_battery(link);
        break;
    case IB_CMD_PING:
        send_to(link, msg, ib_format_pong(msg, sizeof(msg)));
        break;
    case IB_CMD_CONFIG:
        if (cmd->has_mic) s_cfg_mic = cmd->mic;
        if (cmd->has_sound) s_cfg_sound = cmd->sound;
        if (cmd->has_screen_off) s_screen_off_ms = (int64_t)cmd->screen_off_s * 1000;
        if (cmd->has_engine && s_ui_ok) ib_ui_set_engine(cmd->engine);
        if (cmd->has_clock) {
            s_clock_valid = true;
            s_clock_local = cmd->clock;
            s_clock_synced_ms = now;
            refresh_clock(now, true);
        }
        wake(now);
        break;
    case IB_CMD_STATE:
        apply_state(cmd, now);
        break;
    case IB_CMD_LEVEL:
        if (s_ui_ok) ib_ui_set_level(cmd->level);
        break;
    case IB_CMD_MIC:
        if (cmd->on) {
            mic_start(link, false, now);
        } else {
            mic_stop();
        }
        break;
    case IB_CMD_KEYS:
        for (int k = 0; k < IB_KEY_COUNT; k++) {
            if (cmd->has_key_icon[k] && s_ui_ok) ib_ui_set_key_icon((ib_ui_key_t)k, cmd->key_icon[k]);
        }
        break;
    case IB_CMD_AGENT:
        if (cmd->agent_ev == IB_AGENT_CLEAR) {
            agent_clear();
        } else {
            agent_show(cmd->agent_ev, cmd->has_msg ? cmd->msg : "", now);
        }
        break;
    case IB_CMD_LIST:
        apply_list(cmd);
        break;
    case IB_CMD_BYE:
        break;
    }
}

// ---- 周期任务 ----

static void refresh_timers(int64_t now)
{
    if (s_revert_at && now >= s_revert_at) {
        s_revert_at = 0;
        if (s_online && (s_screen == IB_UI_DONE || s_screen == IB_UI_ERR)) {
            // 回到常驻页面(idle 或字幕页)和它的模式,Mac 随后的状态会再确认一次。
            s_st = s_home_st;
            s_mode = s_home_mode;
            memcpy(s_msg, s_home_msg, sizeof(s_msg));
            show_screen(screen_for(s_st));
        }
    }
    if (s_mic_local && s_st != IB_ST_REC && now - s_mic_local_ms > MIC_LOCAL_WAIT_MS) mic_stop();
    if (s_mic_tail_until && now >= s_mic_tail_until) {
        s_mic_tail_until = 0;
        if (s_st != IB_ST_REC && s_audio_ok && ib_audio_mic_active()) mic_stop();
    }

    if (s_agent_on) {
        if (s_agent_kind == IB_AGENT_DONE && now >= s_agent_deadline) {
            agent_clear();
        } else if (s_agent_kind == IB_AGENT_INPUT && now >= s_agent_next_chime) {
            s_agent_next_chime = now + AGENT_CHIME_MS;
            play(IB_SOUND_AGENT_INPUT);
            wake(now);
        }
    }
}

static void refresh_backlight(int64_t now)
{
    // 录音、处理中、字幕运行中保持常亮;其余时间按 config.screen_off 熄屏(0 为永不)。
    bool busy = s_online && (s_st == IB_ST_REC || s_st == IB_ST_PROC || s_st == IB_ST_SUB);
    if (busy) s_last_activity_ms = now;
    bool on = s_screen_off_ms == 0 || now - s_last_activity_ms < s_screen_off_ms;
    set_backlight(on);
}

static void app_task(void *arg)
{
    (void)arg;
    app_event_t ev;
    refresh_battery(now_ms(), true);
    refresh_clock(now_ms(), true);
    for (;;) {
        if (xQueueReceive(s_queue, &ev, pdMS_TO_TICKS(LOOP_PERIOD_MS)) == pdTRUE) {
            int64_t now = now_ms();
            switch (ev.type) {
            case EV_KEY:
                handle_key(ev.key, ev.key_ev, now);
                break;
            case EV_COMMAND:
                handle_command(ev.link, &ev.cmd, now);
                break;
            case EV_BLE_LINK:
                s_ble_subscribed = ev.subscribed;
                if (!ev.subscribed) ib_links_drop(&s_links, IB_LINK_BLE);
                break;
            }
        }
        int64_t now = now_ms();
        refresh_links(now);
        refresh_timers(now);
        refresh_battery(now, false);
        refresh_clock(now, false);
        refresh_backlight(now);
    }
}

esp_err_t ib_app_start(bool ui_ok, bool battery_ok)
{
    s_ui_ok = ui_ok;
    s_battery_ok = battery_ok;
    // 构建标识:esptool elf2image 写进镜像的 ELF SHA-256(小写十六进制),取前 8 位。
    esp_app_get_elf_sha256(s_build_id, sizeof(s_build_id));
    ib_links_init(&s_links);
    ib_keys_reset(&s_keys);

    s_queue = xQueueCreate(EVENT_QUEUE_LEN, sizeof(app_event_t));
    ESP_RETURN_ON_FALSE(s_queue, ESP_ERR_NO_MEM, TAG, "event queue alloc failed");

    if (s_ui_ok && ib_ui_init() != ESP_OK) {
        ESP_LOGE(TAG, "UI init failed, continue without screen");
        s_ui_ok = false;
    }
    wake(now_ms());

    if (ib_usb_start(on_usb_line) != ESP_OK) ESP_LOGE(TAG, "USB link unavailable");

    // BLE 控制器需要 NVS 保存 PHY 校准数据。初始化失败时不擦除分区(避免清掉已有数据),
    // PHY 退回每次上电完整校准,BLE 照常启动。
    esp_err_t err = nvs_flash_init();
    if (err != ESP_OK) ESP_LOGW(TAG, "nvs init failed: %s", esp_err_to_name(err));
    if (ib_ble_start(on_ble_line, on_ble_link) != ESP_OK) ESP_LOGE(TAG, "BLE link unavailable");

    // boot id 在 RF 启用之后生成:此时 esp_random() 由射频噪声提供真随机数。
    s_boot_id = esp_random();

    s_audio_ok = ib_audio_init(audio_tx) == ESP_OK;
    if (!s_audio_ok) ESP_LOGE(TAG, "audio unavailable");

    BaseType_t ok = xTaskCreate(app_task, "ib_app", APP_TASK_STACK, NULL, APP_TASK_PRIO, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "app task create failed");
    return ESP_OK;
}
