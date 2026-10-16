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
};

static lv_obj_t *s_roots[IB_UI_SCREEN_COUNT];
static ib_ui_screen_t s_screen = IB_UI_OFFLINE;
static ib_ui_ctx_t s_ctx;
static lv_timer_t *s_frame_timer;
static bool s_ready;

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

// IDLE 页上 msg 为 "LIVE" 表示 Mac 正在后台跑字幕(听写 / 翻译模式下 OK 仍用于听写):
// 状态栏左侧显示与 SUB 页相同的 LIVE 徽章,msg 清空后恢复链路文字。
#define IB_UI_IDLE_LIVE_MSG "LIVE"

static ib_bar_mode_t bar_mode_for(ib_ui_screen_t screen)
{
    if (screen == IB_UI_REC) return IB_BAR_REC;
    if (screen == IB_UI_SUB) return IB_BAR_LIVE;
    if (screen == IB_UI_IDLE && strcmp(s_ctx.msg, IB_UI_IDLE_LIVE_MSG) == 0) return IB_BAR_LIVE;
    return IB_BAR_NORMAL;
}

static void switch_to(ib_ui_screen_t screen)
{
    uint32_t now = lv_tick_get();
    lv_obj_t *old = s_roots[s_screen];
    lv_obj_t *neu = s_roots[screen];

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

    // 页面都放在状态栏下方的一个图层里;切换时只在该图层内调整前后顺序,不会盖住状态栏。
    lv_obj_t *pages = ib_box_create(scr, 0, IB_UI_BAR_H, IB_UI_W, IB_UI_PAGE_H);
    for (int i = 0; i < IB_UI_SCREEN_COUNT; i++) {
        s_roots[i] = PAGES[i]->create(pages, &s_ctx);
        lv_obj_add_flag(s_roots[i], LV_OBJ_FLAG_HIDDEN);
    }
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
    if (awake) {
        lv_timer_resume(s_frame_timer);
    } else {
        lv_timer_pause(s_frame_timer);
    }
    bsp_lvgl_unlock();
}
