// main/ib_ui.c: UI 核心:屏幕根对象、页面调度与切换动画、逐帧定时器、对外接口加锁。
//
// 页面切换采用"淡出后再淡入"(fade-through),两页不会叠在一起:
//   旧页面 120 ms 淡出(ease-in)后隐藏;新页面在旧页面淡完后 180 ms 淡入并从下方 8 px 缓动上移(ease-out),
//   页面内部的自绘动画以新页面开始淡入的时刻为 enter_ms(图标等做轻微放大)。
// 只用 opa / translate 样式,不触发 LVGL 图层缓冲(C3 内存放不下整页图层)。
//
// 逐帧定时器(33 ms ≈ 30 fps)运行在 LVGL 任务里:平滑电平、驱动状态栏、当前页面与 Agent 通知层的
// frame()。熄屏时暂停定时器,不产生任何重绘;Agent 全屏通知盖住页面时页面也不再逐帧重绘。
//
// 图层顺序(由下到上):页面层 → 状态栏 → 右侧按键提示列 → Agent 通知层。
#include "ib_ui.h"

#include "bsp_display.h"
#include "ib_ui_agent.h"
#include "ib_ui_gfx.h"
#include "ib_ui_hints.h"
#include "ib_ui_page.h"
#include "ib_ui_statusbar.h"

#include "esp_log.h"

#include <string.h>

static const char *TAG = "ib_ui";

#define LOCK_TIMEOUT_MS 1000
#define FRAME_MS        33
#define FADE_OUT_MS     120
#define FADE_IN_MS      180
#define RISE_PX         8

static const ib_ui_page_t *const PAGES[IB_UI_SCREEN_COUNT] = {
    [IB_UI_OFFLINE] = &ib_ui_page_offline,
    [IB_UI_IDLE] = &ib_ui_page_idle,
    [IB_UI_REC] = &ib_ui_page_rec,
    [IB_UI_PROC] = &ib_ui_page_proc,
    [IB_UI_DONE] = &ib_ui_page_done,
    [IB_UI_ERR] = &ib_ui_page_err,
    [IB_UI_SUB] = &ib_ui_page_sub,
    [IB_UI_LIST] = &ib_ui_page_list,
    [IB_UI_USAGE] = &ib_ui_page_usage,
};

static lv_obj_t *s_roots[IB_UI_SCREEN_COUNT];
static lv_obj_t *s_footer;
static lv_obj_t *s_footer_time;
static ib_ui_screen_t s_screen = IB_UI_OFFLINE;
static ib_ui_ctx_t s_ctx;
static lv_timer_t *s_frame_timer;
static bool s_ready;
static bool s_awake = true;

static void copy_text(char *dst, size_t cap, const char *src)
{
    size_t n = 0;
    if (src) {
        for (; src[n] && n + 1 < cap; n++) {
            char ch = src[n];
            dst[n] = (ch >= 0x20 && ch < 0x7F) ? ch : '?';   // 字体只有 ASCII
        }
    }
    dst[n] = '\0';
}

// 字幕字段保留 UTF-8;只在完整字符边界截断。
static void copy_utf8(char *dst, size_t cap, const char *src)
{
    size_t n = 0;
    while (src && src[n] && n + 1 < cap) {
        unsigned char ch = (unsigned char)src[n];
        size_t len = ch < 0x80 ? 1 : (ch & 0xE0) == 0xC0 ? 2 : (ch & 0xF0) == 0xE0 ? 3 : (ch & 0xF8) == 0xF0 ? 4 : 0;
        if (len == 0 || n + len + 1 > cap) break;
        memcpy(dst + n, src + n, len);
        n += len;
    }
    dst[n] = '\0';
}

// ---------------------------------------------------------------------------
// 页面切换动画(LVGL 任务)
// ---------------------------------------------------------------------------

static void opa_cb(void *obj, int32_t v)
{
    lv_obj_set_style_opa(obj, (lv_opa_t)v, 0);
}

static void rise_cb(void *obj, int32_t v)
{
    lv_obj_set_style_translate_y(obj, v, 0);
}

static void hide_done_cb(lv_anim_t *a)
{
    lv_obj_t *obj = a->var;
    // 淡出期间若又被切回来,会先删除这个动画,因此走到这里一定是仍需隐藏。
    lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
}

static void anim_start(lv_obj_t *obj, lv_anim_exec_xcb_t cb, int32_t from, int32_t to, uint32_t delay, uint32_t ms,
                       lv_anim_path_cb_t path, lv_anim_completed_cb_t done)
{
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, obj);
    lv_anim_set_exec_cb(&a, cb);
    lv_anim_set_values(&a, from, to);
    lv_anim_set_delay(&a, delay);
    lv_anim_set_duration(&a, ms);
    lv_anim_set_path_cb(&a, path);
    if (done) lv_anim_set_completed_cb(&a, done);
    lv_anim_start(&a);
}

static ib_bar_mode_t bar_mode_for(ib_ui_screen_t screen)
{
    if (screen == IB_UI_REC) return IB_BAR_REC;
    if (screen == IB_UI_SUB) return IB_BAR_LIVE;
    return IB_BAR_NORMAL;
}

// 主体是点阵的页面(ib_ui_dots)之间"直切":新页面接着上一页的最后一帧让点重排(见 ib_ui_page.h);
// OFFLINE / LIST 与它们之间仍是淡入淡出。
static bool dot_page(ib_ui_screen_t s)
{
    return s == IB_UI_IDLE || s == IB_UI_REC || s == IB_UI_PROC || s == IB_UI_DONE || s == IB_UI_ERR || s == IB_UI_SUB;
}

static bool cut_transition(ib_ui_screen_t from, ib_ui_screen_t to)
{
    return from != to && dot_page(from) && dot_page(to);
}

// 点阵交互页共用页脚时钟;离线页已有大时钟,列表和字幕页保持原有布局。
static void footer_show(ib_ui_screen_t screen)
{
    if (screen == IB_UI_IDLE || screen == IB_UI_REC || screen == IB_UI_PROC ||
        screen == IB_UI_DONE || screen == IB_UI_ERR) lv_obj_remove_flag(s_footer, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_footer, LV_OBJ_FLAG_HIDDEN);
}

static void switch_to(ib_ui_screen_t screen)
{
    footer_show(screen);
    uint32_t now = lv_tick_get();
    lv_obj_t *old = s_roots[s_screen];
    lv_obj_t *neu = s_roots[screen];
    // 旧页面还没完全显示出来(例如正在淡入)时不直切,免得新页面从一个没出现过的画面开始变形。
    bool dot_cut = cut_transition(s_screen, screen) && !lv_obj_has_flag(old, LV_OBJ_FLAG_HIDDEN) &&
                   lv_obj_get_style_opa(old, 0) == LV_OPA_COVER;
    bool cut = !s_awake || dot_cut;
    s_ctx.prev_screen = dot_cut && s_awake ? s_screen : IB_UI_SCREEN_NONE;

    if (cut) {
        lv_anim_delete(old, NULL);
        lv_anim_delete(neu, NULL);
        lv_obj_add_flag(old, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(neu, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_opa(neu, LV_OPA_COVER, 0);
        lv_obj_set_style_translate_y(neu, 0, 0);
        lv_obj_move_foreground(neu);
        s_screen = screen;
        s_ctx.enter_ms = now;
        s_ctx.now_ms = now;
        ib_bar_set_mode(bar_mode_for(screen), now);
        ib_hints_set_visible(true);
        ib_hints_set_disabled(screen == IB_UI_PROC);
        ib_agent_set_banner(screen == IB_UI_REC, now);
        PAGES[screen]->enter(&s_ctx);
        return;
    }

    uint32_t delay = 0;
    if (old != neu) {
        lv_anim_delete(old, NULL);
        lv_opa_t from = lv_obj_get_style_opa(old, 0);
        if (lv_obj_has_flag(old, LV_OBJ_FLAG_HIDDEN)) from = LV_OPA_TRANSP;
        // 旧页面已经淡掉一部分时按剩余比例缩短淡出,新页面紧接着开始淡入。
        delay = (uint32_t)FADE_OUT_MS * from / LV_OPA_COVER;
        anim_start(old, opa_cb, from, LV_OPA_TRANSP, 0, delay > 0 ? delay : 1, lv_anim_path_ease_in, hide_done_cb);
    }
    lv_anim_delete(neu, NULL);
    lv_obj_remove_flag(neu, LV_OBJ_FLAG_HIDDEN);
    lv_obj_set_style_opa(neu, LV_OPA_TRANSP, 0);
    lv_obj_set_style_translate_y(neu, RISE_PX, 0);
    lv_obj_move_foreground(neu);
    anim_start(neu, opa_cb, LV_OPA_TRANSP, LV_OPA_COVER, delay, FADE_IN_MS, lv_anim_path_ease_out, NULL);
    anim_start(neu, rise_cb, RISE_PX, 0, delay, FADE_IN_MS, lv_anim_path_ease_out, NULL);

    s_screen = screen;
    s_ctx.enter_ms = now + delay;       // 页面动画从开始淡入时算起
    s_ctx.now_ms = now;
    ib_bar_set_mode(bar_mode_for(screen), now);
    ib_hints_set_visible(screen != IB_UI_OFFLINE);
    ib_hints_set_disabled(screen == IB_UI_PROC);    // 上一句还在处理:按键暂不可用
    // 录音中通知只显示横幅,离开录音后恢复全屏。
    ib_agent_set_banner(screen == IB_UI_REC, now);
    PAGES[screen]->enter(&s_ctx);
}

static void frame_cb(lv_timer_t *t)
{
    (void)t;
    s_ctx.now_ms = lv_tick_get();
    // 电平平滑:每帧向目标靠近 35%,0..1000 定点。
    int32_t target = (int32_t)s_ctx.level * 10;
    s_ctx.level_smooth += (target - s_ctx.level_smooth) * 35 / 100;
    ib_bar_frame(s_ctx.now_ms);
    // 新页面还在等旧页面淡出(enter_ms 在未来)时不推进它的动画。
    bool started = (int32_t)(s_ctx.now_ms - s_ctx.enter_ms) >= 0;
    if (started && !ib_agent_covering()) PAGES[s_screen]->frame(&s_ctx);
    ib_agent_frame(s_ctx.now_ms);
}

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------

esp_err_t ib_ui_init(void)
{
    if (!bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return ESP_ERR_TIMEOUT;

    lv_obj_t *scr = lv_screen_active();
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(scr, IB_C(IB_COLOR_BG), 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);

    copy_text(s_ctx.time, sizeof(s_ctx.time), "");
    s_ctx.mode = IB_UI_MODE_DICT;
    s_ctx.now_ms = lv_tick_get();

    // 离线页铺满全屏，其他页面仍从状态栏下方开始。整个页面层位于状态栏之下。
    lv_obj_t *pages = ib_box_create(scr, 0, 0, IB_UI_W, IB_UI_H);
    for (int i = 0; i < IB_UI_SCREEN_COUNT; i++) {
        s_roots[i] = PAGES[i]->create(pages, &s_ctx);
        if (i != IB_UI_OFFLINE) lv_obj_set_y(s_roots[i], IB_UI_BAR_H);
        lv_obj_add_flag(s_roots[i], LV_OBJ_FLAG_HIDDEN);
    }
    s_footer = ib_box_create(scr, 10, 287, IB_UI_CONTENT_W - 20, 25);
    lv_obj_t *line = ib_box_create(s_footer, 0, 0, IB_UI_CONTENT_W - 20, 1);
    lv_obj_set_style_bg_color(line, IB_C(IB_COLOR_MATRIX_FRAME), 0);
    lv_obj_set_style_bg_opa(line, LV_OPA_COVER, 0);
    s_footer_time = ib_label_create(s_footer, &ib_terminal_font_12, IB_COLOR_MATRIX_SOFT, 6, IB_UI_CONTENT_W - 20);
    lv_obj_set_style_text_align(s_footer_time, LV_TEXT_ALIGN_LEFT, 0);
    lv_label_set_text_static(s_footer_time, "TIME // --:--");
    lv_obj_add_flag(s_footer, LV_OBJ_FLAG_HIDDEN);
    ib_bar_create(scr);     // 后建,位于页面之上
    ib_hints_create(scr);
    ib_hints_set_visible(false);
    ib_agent_create(scr);   // 最上层

    s_screen = IB_UI_OFFLINE;
    lv_obj_remove_flag(s_roots[s_screen], LV_OBJ_FLAG_HIDDEN);
    s_ctx.enter_ms = s_ctx.now_ms;
    PAGES[s_screen]->enter(&s_ctx);

    s_frame_timer = lv_timer_create(frame_cb, FRAME_MS, NULL);
    s_ready = true;
    bsp_lvgl_unlock();
    return s_frame_timer ? ESP_OK : ESP_ERR_NO_MEM;
}

bool ib_ui_show(ib_ui_screen_t screen, ib_ui_mode_t mode, const char *msg)
{
    if (!s_ready || (unsigned)screen >= IB_UI_SCREEN_COUNT || (unsigned)mode >= IB_UI_MODE_COUNT) return false;
    if (!bsp_lvgl_lock(LOCK_TIMEOUT_MS)) {
        ESP_LOGW(TAG, "lock timeout (show)");
        return false;
    }
    bool changed = s_ctx.mode != mode || strncmp(s_ctx.msg, msg ? msg : "", sizeof(s_ctx.msg)) != 0;
    s_ctx.mode = mode;
    copy_text(s_ctx.msg, sizeof(s_ctx.msg), msg);
    if (screen != s_screen) {
        switch_to(screen);
    } else if (changed) {
        ib_bar_set_mode(bar_mode_for(screen), lv_tick_get());     // 例如 IDLE 上 LIVE 徽章出现 / 消失
        PAGES[screen]->update(&s_ctx);
    }
    bsp_lvgl_unlock();
    return true;
}

void ib_ui_set_level(uint8_t level)
{
    // 单字节写入,LVGL 任务每帧读取;不需要加锁。
    s_ctx.level = level > 100 ? 100 : level;
}

void ib_ui_set_caption(const char *src, const char *dst, const char *app, bool live)
{
    if (!s_ready) return;
    const char *s = src ? src : "";
    const char *d = dst ? dst : "";
    const char *a = app ? app : "";
    bool changed = s_ctx.caption_live != live ||
                   strncmp(s_ctx.caption_src, s, sizeof(s_ctx.caption_src)) != 0 ||
                   strncmp(s_ctx.caption_dst, d, sizeof(s_ctx.caption_dst)) != 0 ||
                   strncmp(s_ctx.caption_app, a, sizeof(s_ctx.caption_app)) != 0;
    if (!changed) return;
    if (!bsp_lvgl_lock(LOCK_TIMEOUT_MS)) {
        ESP_LOGW(TAG, "lock timeout (caption)");
        return;
    }
    copy_utf8(s_ctx.caption_src, sizeof(s_ctx.caption_src), s);
    copy_utf8(s_ctx.caption_dst, sizeof(s_ctx.caption_dst), d);
    copy_utf8(s_ctx.caption_app, sizeof(s_ctx.caption_app), a);
    s_ctx.caption_live = live;
    if (s_screen == IB_UI_SUB) PAGES[IB_UI_SUB]->update(&s_ctx);
    bsp_lvgl_unlock();
}

void ib_ui_set_ok_held(bool held)
{
    if (!s_ready || s_ctx.ok_held == held || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    s_ctx.ok_held = held;
    if (s_screen == IB_UI_REC) PAGES[s_screen]->update(&s_ctx);
    bsp_lvgl_unlock();
}

void ib_ui_set_link(ib_ui_link_t link, bool online)
{
    if (!s_ready || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    ib_bar_set_link(link, online);
    bsp_lvgl_unlock();
}

void ib_ui_set_battery(int soc, bool charging)
{
    if (!s_ready || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    ib_bar_set_battery(soc, charging);
    bsp_lvgl_unlock();
}

void ib_ui_set_clock(const char *time, const char *date)
{
    if (!s_ready || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    copy_text(s_ctx.time, sizeof(s_ctx.time), time);
    copy_text(s_ctx.date, sizeof(s_ctx.date), date);
    lv_label_set_text_fmt(s_footer_time, "TIME // %s", s_ctx.time[0] ? s_ctx.time : "--:--");
    if (s_screen == IB_UI_OFFLINE) PAGES[IB_UI_OFFLINE]->update(&s_ctx);
    bsp_lvgl_unlock();
}

void ib_ui_set_offline_hint(const char *text)
{
    if (!s_ready) return;
    char hint[IB_UI_OFFLINE_HINT_MAX];
    copy_text(hint, sizeof(hint), text);
    if (strncmp(s_ctx.offline_hint, hint, sizeof(hint)) == 0) return;
    if (!bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    memcpy(s_ctx.offline_hint, hint, sizeof(hint));
    if (s_screen == IB_UI_OFFLINE) PAGES[IB_UI_OFFLINE]->update(&s_ctx);
    bsp_lvgl_unlock();
}

void ib_ui_set_engine(const char *engine)
{
    if (!s_ready || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    copy_text(s_ctx.engine, sizeof(s_ctx.engine), engine);
    if (s_screen == IB_UI_IDLE) PAGES[IB_UI_IDLE]->update(&s_ctx);
    bsp_lvgl_unlock();
}

void ib_ui_key_press(ib_ui_key_t key)
{
    // 离线页不显示提示列,也就没有按键反馈(按键只用于点亮屏幕)。
    if (!s_ready || s_screen == IB_UI_OFFLINE || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    ib_hints_press(key);
    bsp_lvgl_unlock();
}

void ib_ui_set_key_icon(ib_ui_key_t key, ib_icon_t icon)
{
    if (!s_ready || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    ib_hints_set_icon(key, icon);
    bsp_lvgl_unlock();
}

void ib_ui_set_list(const ib_ui_list_t *list)
{
    if (!s_ready || !list || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    s_ctx.list = *list;
    if (s_screen == IB_UI_LIST) PAGES[IB_UI_LIST]->update(&s_ctx);
    bsp_lvgl_unlock();
}

void ib_ui_set_usage(const ib_ui_usage_t *usage)
{
    if (!s_ready || !usage || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    ib_ui_usage_t next = *usage;
    copy_text(next.app, sizeof(next.app), usage->app);
    copy_text(next.today, sizeof(next.today), usage->today);
    copy_text(next.week, sizeof(next.week), usage->week);
    copy_text(next.total, sizeof(next.total), usage->total);
    copy_text(next.reset, sizeof(next.reset), usage->reset);
    copy_text(next.plan, sizeof(next.plan), usage->plan);
    if (next.tab > 2) next.tab = 0;
    if (next.left_percent > 100) next.left_percent = 100;
    if (next.five_hour_left_percent > 100) next.five_hour_left_percent = 100;
    for (int i = 0; i < 2; i++) {
        if (next.panel_percent[i] > 100) next.panel_percent[i] = 100;
    }
    s_ctx.usage = next;
    if (s_screen == IB_UI_USAGE) PAGES[IB_UI_USAGE]->update(&s_ctx);
    bsp_lvgl_unlock();
}

void ib_ui_agent_show(ib_ui_agent_t kind, const char *source)
{
    if (!s_ready || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    ib_agent_show(kind, source, s_screen == IB_UI_REC, lv_tick_get());
    bsp_lvgl_unlock();
}

void ib_ui_agent_hide(void)
{
    if (!s_ready || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    ib_agent_hide();
    bsp_lvgl_unlock();
}

void ib_ui_set_awake(bool awake)
{
    if (!s_ready || !bsp_lvgl_lock(LOCK_TIMEOUT_MS)) return;
    s_awake = awake;
    if (awake) {
        lv_timer_resume(s_frame_timer);
    } else {
        lv_timer_pause(s_frame_timer);
    }
    bsp_lvgl_unlock();
}
