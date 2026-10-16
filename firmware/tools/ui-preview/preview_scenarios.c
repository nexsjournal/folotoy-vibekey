// tools/ui-preview/preview_scenarios.c: 预览场景实现。
//
// 场景是一条连续的"剧本":与真机一样只通过 ib_ui.h 的公开接口改变界面(这些调用与 ib_app.c 中的一致),
// 用 preview_advance() 推进虚拟时间,在关键时刻截图——包括动画中途的帧(文件名带 _<N>ms,
// N 为距离触发调用的毫秒数)。页面切换是"淡出 120 ms 后再淡入 180 ms",所以 _fade_60ms 是旧页面
// 正在淡出、_fade_200ms 是新页面正在淡入。
// 新增场景时按顺序追加即可;编号决定输出文件的排序。
#include "preview_scenarios.h"

#include "ib_ui.h"
#include "preview_host.h"

#include <stdio.h>
#include <string.h>

static const char *s_out_dir;
static const char *s_filter;
static int s_scale;
static int s_index;
static int s_failures;

static void shot(const char *name)
{
    char path[512];
    s_index++;
    snprintf(path, sizeof(path), "%s/%02d_%s.png", s_out_dir, s_index, name);
    if (s_filter && !strstr(path, s_filter)) return;
    if (preview_capture(path, s_scale)) {
        printf("  %s\n", path);
    } else {
        fprintf(stderr, "保存失败:%s\n", path);
        s_failures++;
    }
}

static void keys(ib_icon_t up, ib_icon_t down, ib_icon_t ok)
{
    ib_ui_set_key_icon(IB_UI_KEY_UP, up);
    ib_ui_set_key_icon(IB_UI_KEY_DOWN, down);
    ib_ui_set_key_icon(IB_UI_KEY_OK, ok);
}

static void set_list(uint16_t sel, uint16_t top)
{
    static const char *const APPS[] = { "Ghostty", "Chrome", "Xcode", "Finder", "Mail", "Notes", "Slack" };
    const uint16_t n = (uint16_t)(sizeof(APPS) / sizeof(APPS[0]));
    ib_ui_list_t l;
    memset(&l, 0, sizeof(l));
    snprintf(l.title, sizeof(l.title), "SWITCH APP");
    for (uint16_t i = 0; i < IB_UI_LIST_ROWS && top + i < n; i++) {
        snprintf(l.items[i], sizeof(l.items[i]), "%s", APPS[top + i]);
        l.rows = (uint8_t)(i + 1);
    }
    l.n = n;
    l.top = top;
    l.sel = sel;
    ib_ui_set_list(&l);
}

int preview_run_scenarios(const char *out_dir, int scale, const char *filter)
{
    s_out_dir = out_dir;
    s_scale = scale;
    s_filter = filter;
    s_index = 0;
    s_failures = 0;

    // ---- OFFLINE:Mac 未连接,USB 线插着 ----
    ib_ui_set_link(IB_UI_LINK_USB, false);
    ib_ui_set_battery(87, false);
    ib_ui_set_clock("23:41", "THU 10/15");
    preview_advance(1500);
    shot("offline_clock");

    // ---- IDLE:握手后 Mac 下发 config / keys / state ----
    ib_ui_set_link(IB_UI_LINK_USB, true);
    ib_ui_set_engine("Whisper Turbo");
    keys(IB_ICON_ENTER, IB_ICON_ESC, IB_ICON_MIC);
    ib_ui_show(IB_UI_IDLE, IB_UI_MODE_DICT, "");
    preview_advance(60);
    shot("offline_to_idle_fade_60ms");
    preview_advance(140);
    shot("offline_to_idle_fade_200ms");
    preview_advance(1000);
    shot("idle_dict");

    ib_ui_show(IB_UI_IDLE, IB_UI_MODE_TR, "");      // 模式切换:左右滑动
    preview_advance(100);
    shot("idle_dict_to_tr_100ms");
    preview_advance(600);
    shot("idle_tr");

    keys(IB_ICON_MODE, IB_ICON_HIDE, IB_ICON_PLAY);
    ib_ui_show(IB_UI_IDLE, IB_UI_MODE_SUB, "");
    preview_advance(700);
    shot("idle_sub");
    ib_ui_key_press(IB_UI_KEY_OK);                  // 按键反馈:提示图标闪白
    preview_advance(40);
    shot("idle_sub_press_ok_40ms");
    preview_advance(400);

    // ---- REC:按住说话 → 免提 → 翻译模式 ----
    keys(IB_ICON_NONE, IB_ICON_CANCEL, IB_ICON_STOP);
    ib_ui_show(IB_UI_IDLE, IB_UI_MODE_DICT, "");
    preview_advance(400);
    ib_ui_set_ok_held(true);
    ib_ui_set_level(15);
    ib_ui_show(IB_UI_REC, IB_UI_MODE_DICT, "");
    preview_advance(60);
    shot("idle_to_rec_fade_60ms");
    preview_advance(140);
    shot("idle_to_rec_fade_200ms");
    preview_advance(1000);
    shot("rec_hold_low_level");
    ib_ui_set_level(90);
    preview_advance(600);
    shot("rec_hold_high_level");
    ib_ui_set_ok_held(false);
    ib_ui_set_level(50);
    preview_advance(400);
    shot("rec_handsfree");
    ib_ui_show(IB_UI_REC, IB_UI_MODE_TR, "");
    preview_advance(400);
    shot("rec_translate");
    ib_ui_set_level(0);

    // ---- PROC / DONE / ERR ----
    keys(IB_ICON_NONE, IB_ICON_NONE, IB_ICON_NONE);
    ib_ui_show(IB_UI_PROC, IB_UI_MODE_DICT, "");
    preview_advance(700);
    shot("proc");

    ib_ui_show(IB_UI_DONE, IB_UI_MODE_DICT, "");
    preview_advance(60);
    shot("proc_to_done_fade_60ms");
    preview_advance(140);
    shot("done_200ms");
    preview_advance(300);
    shot("done_500ms");
    preview_advance(250);
    shot("done_750ms");
    preview_advance(600);
    shot("done");

    ib_ui_show(IB_UI_ERR, IB_UI_MODE_DICT, "NO SPEECH");
    preview_advance(60);
    shot("done_to_err_fade_60ms");
    preview_advance(150);                           // 淡入开始后约 90 ms:抖动中
    shot("err_shake_210ms");
    preview_advance(700);
    shot("err");

    // ---- SUB:字幕运行中 ----
    keys(IB_ICON_TRANSLATE, IB_ICON_HIDE, IB_ICON_STOP);
    ib_ui_set_level(60);
    ib_ui_show(IB_UI_SUB, IB_UI_MODE_SUB, "Chrome");
    preview_advance(900);
    shot("sub");
    ib_ui_set_level(0);

    // ---- LIST:应用切换器(7 项)----
    keys(IB_ICON_UP, IB_ICON_DOWN, IB_ICON_OPEN);
    set_list(0, 0);
    ib_ui_show(IB_UI_LIST, IB_UI_MODE_DICT, "");
    preview_advance(500);
    shot("list_sel0");
    set_list(4, 0);
    preview_advance(60);
    shot("list_sel4_sliding_60ms");
    preview_advance(400);
    shot("list_sel4");
    set_list(6, 1);
    preview_advance(400);
    shot("list_sel6_scrolled");

    // ---- AGENT 通知 ----
    keys(IB_ICON_ENTER, IB_ICON_ESC, IB_ICON_MIC);
    ib_ui_show(IB_UI_IDLE, IB_UI_MODE_DICT, "");
    preview_advance(500);
    ib_ui_agent_show(IB_UI_AGENT_DONE, "Claude Code");   // 先铺黑色背景 100 ms,再淡入内容
    preview_advance(50);
    shot("agent_done_backdrop_50ms");
    preview_advance(100);
    shot("agent_done_150ms");
    preview_advance(1500);
    shot("agent_done");
    ib_ui_agent_hide();                                  // 先淡出内容 120 ms,再撤背景 100 ms
    preview_advance(60);
    shot("agent_dismiss_60ms");
    preview_advance(110);
    shot("agent_dismiss_170ms");
    preview_advance(200);

    ib_ui_agent_show(IB_UI_AGENT_INPUT, "Claude Code");
    preview_advance(900);
    shot("agent_input");
    preview_advance(2450);                          // 第二次摇摆的中段
    shot("agent_input_wiggle");
    ib_ui_agent_hide();
    preview_advance(300);

    // 录音中收到通知:只显示顶部横幅
    keys(IB_ICON_NONE, IB_ICON_CANCEL, IB_ICON_STOP);
    ib_ui_set_ok_held(true);
    ib_ui_set_level(40);
    ib_ui_show(IB_UI_REC, IB_UI_MODE_DICT, "");
    preview_advance(300);
    ib_ui_agent_show(IB_UI_AGENT_INPUT, "Claude Code");
    preview_advance(800);
    shot("rec_agent_banner");
    ib_ui_agent_hide();
    ib_ui_set_ok_held(false);
    ib_ui_set_level(0);

    // ---- 状态栏:低电量 / BLE + 充电 ----
    keys(IB_ICON_ENTER, IB_ICON_ESC, IB_ICON_MIC);
    ib_ui_show(IB_UI_IDLE, IB_UI_MODE_DICT, "");
    ib_ui_set_battery(12, false);
    preview_advance(800);
    shot("idle_low_battery");
    ib_ui_set_link(IB_UI_LINK_BLE, true);
    ib_ui_set_battery(64, true);
    preview_advance(300);
    shot("idle_ble_charging");

    // ---- 听写模式下 Mac 后台跑字幕:IDLE + msg "LIVE" → 状态栏显示 LIVE 徽章 ----
    ib_ui_set_link(IB_UI_LINK_USB, true);
    ib_ui_set_battery(87, false);
    ib_ui_show(IB_UI_IDLE, IB_UI_MODE_DICT, "LIVE");
    preview_advance(600);
    shot("idle_dict_live");
    ib_ui_show(IB_UI_IDLE, IB_UI_MODE_DICT, "");    // 字幕停止:恢复链路文字
    preview_advance(300);
    shot("idle_dict_live_off");

    return s_failures;
}
