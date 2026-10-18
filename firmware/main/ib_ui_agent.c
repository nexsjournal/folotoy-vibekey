// main/ib_ui_agent.c: Agent 通知层实现(见 ib_ui_agent.h)。
//
// 全屏通知(时间线从出现起):主体是大号点阵(对勾 / 感叹号),点从屏幕外一圈飞入拼成(约 450 ms);
//   done 之后静止不再重绘;input 整体亮度 2.4 s 周期呼吸。标题 DONE / YOUR TURN、来源名;
//   只有 input(需要用户动作)显示 "press any key"。
// 录音中的横幅:小圆形图标(实心圆 + 对勾 / "!",input 每 3 s 摇摆一次)+ 来源名。
// "出现"指黑色背景铺满之后(全屏)或横幅开始淡入时。
#include "ib_ui_agent.h"

#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#include <stdio.h>

// 全屏:出现时先铺背景再淡入内容,关闭时先淡出内容再撤背景,任何时刻都不会和下面的页面内容叠在一起。
#define BACKDROP_MS     100     // 黑色背景淡入 / 淡出
#define CONTENT_IN_MS   160     // 背景铺满后内容淡入
#define CONTENT_OUT_MS  120     // 关闭时内容先淡出
#define BANNER_FADE_MS  200     // 横幅整体淡入 / 淡出
#define FX_Y         20
#define FX_H         200
#define ICON_R       38
#define DONE_STILL_MS 600         // 大点阵飞入拼好(最右列 8 ms x 10 + 360 ms)之后静止
#define BREATH_MS    2400
#define WIGGLE_EVERY_MS 3000
#define WIGGLE_MS    1400
#define BANNER_Y     28
#define BANNER_H     28

static lv_obj_t *s_root;
static lv_obj_t *s_full;
static lv_obj_t *s_fx;
static lv_obj_t *s_title;
static lv_obj_t *s_source;
static lv_obj_t *s_banner;
static lv_obj_t *s_banner_icon;
static lv_obj_t *s_banner_text;
static lv_obj_t *s_hint;                // "press any key":只有 input(需要用户动作)才显示,done 15 s 自动关闭

static ib_ui_agent_t s_kind;
static bool s_visible;
static bool s_is_banner;
static bool s_hiding;
static uint32_t s_show_ms;
static char s_source_text[IB_UI_TEXT_MAX];
static char s_banner_buf[40];

// 逐帧计算、绘制回调读取的几何参数。
static int32_t s_breath;
static int32_t s_tilt;                  // "!" 倾角(0.1 度)

static uint32_t kind_color(void)
{
    return s_kind == IB_UI_AGENT_DONE ? IB_COLOR_DONE : IB_COLOR_AGENT;
}

// 以 (cx, cy) 为中心、按 s_tilt 旋转并按 scale 缩放一个相对坐标。
static void xform(int32_t cx, int32_t cy, int32_t scale, int32_t x, int32_t y, int32_t *ox, int32_t *oy)
{
    int32_t c = ib_cos10(s_tilt), s = ib_sin10(s_tilt);
    x = x * scale / IB_P_ONE;
    y = y * scale / IB_P_ONE;
    *ox = cx + ((x * c - y * s) >> 15);
    *oy = cy + ((x * s + y * c) >> 15);
}

// 图标:实心圆 + 深色对勾 / "!"。scale 为 IB_P_ONE 时半径 r。
static void draw_icon(const ib_fx_t *fx, int32_t cx, int32_t cy, int32_t r, int32_t scale)
{
    lv_color_t col = IB_C(kind_color());
    lv_color_t ink = IB_C(IB_COLOR_BG);
    int32_t rr = r * scale / IB_P_ONE;
    if (rr <= 0) return;
    ib_fx_circle(fx, cx, cy, rr, col, LV_OPA_COVER);
    int32_t k = r * scale / ICON_R;                             // 图形相对 ICON_R 的缩放(x1024)
    int32_t w = 7 * r / ICON_R;
    if (w < 2) w = 2;
    if (s_kind == IB_UI_AGENT_DONE) {
        int32_t x1, y1, x2, y2, x3, y3;
        int32_t saved = s_tilt;
        s_tilt = 0;
        xform(cx, cy, k, -17, 1, &x1, &y1);
        xform(cx, cy, k, -5, 13, &x2, &y2);
        xform(cx, cy, k, 18, -12, &x3, &y3);
        s_tilt = saved;
        ib_fx_line(fx, x1, y1, x2, y2, w, ink, LV_OPA_COVER);
        ib_fx_line(fx, x2, y2, x3, y3, w, ink, LV_OPA_COVER);
    } else {
        int32_t x1, y1, x2, y2, xd, yd;
        xform(cx, cy, k, 0, -18, &x1, &y1);
        xform(cx, cy, k, 0, 4, &x2, &y2);
        xform(cx, cy, k, 0, 15, &xd, &yd);
        ib_fx_line(fx, x1, y1, x2, y2, w, ink, LV_OPA_COVER);
        ib_fx_circle(fx, xd, yd, w * 6 / 10 + 1, ink, LV_OPA_COVER);
    }
}

// 全屏通知的主体:与界面同一种点阵语言,只是更大(节距 12、点 7 px)。done = 对勾,input = 感叹号。
// 出现时每颗点从屏幕外一圈(沿它相对中心的方向)飞进来拼成字形:按列错峰 8 ms,单颗 360 ms ease-out。
// input 期间整体亮度随呼吸在 65% ~ 100% 之间变化(彩色与黑混合,不涉及灰色偏色)。
#define BIG_PITCH   12
#define BIG_DOT     7
#define FLY_IN_MS   360
#define FLY_STAGGER 8

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    int32_t cx = fx.w / 2, cy = fx.h / 2;
    ib_dots_t g;
    ib_dots_glyph(&g, s_kind == IB_UI_AGENT_DONE ? IB_DOTS_CHECK : IB_DOTS_BANG, IB_DOT_WHITE);
    if (g.n == 0) return;
    // 字形的网格包围盒中心,作为大点阵的中心。
    int32_t c0 = g.d[0].c, c1 = c0, r0 = g.d[0].r, r1 = r0;
    for (int i = 1; i < g.n; i++) {
        c0 = LV_MIN(c0, g.d[i].c); c1 = LV_MAX(c1, g.d[i].c);
        r0 = LV_MIN(r0, g.d[i].r); r1 = LV_MAX(r1, g.d[i].r);
    }
    uint32_t t = lv_tick_get() - s_show_ms;
    if ((int32_t)t < 0) t = 0;
    lv_color_t col = IB_C(kind_color());
    if (s_kind != IB_UI_AGENT_DONE) col = lv_color_mix(col, IB_C(IB_COLOR_BG), (uint8_t)(166 + s_breath * 89 / IB_P_ONE));
    for (int i = 0; i < g.n; i++) {
        // 目标位置(相对中心,x2 避免半格误差)。
        int32_t tx = ((g.d[i].c - c0) * 2 - (c1 - c0)) * BIG_PITCH / 2;
        int32_t ty = ((g.d[i].r - r0) * 2 - (r1 - r0)) * BIG_PITCH / 2;
        int32_t p = ib_ease_out_cubic(ib_progress(t, (uint32_t)(FLY_STAGGER * (g.d[i].c - c0)), FLY_IN_MS));
        // 起点:沿目标方向推到半径约 170 px 的圆外(正中心的点从正上方进来)。
        int32_t len = lv_sqrt32((uint32_t)(tx * tx + ty * ty));
        int32_t sx = len > 0 ? tx * 170 / len : 0, sy = len > 0 ? ty * 170 / len : -170;
        int32_t x = cx + ib_lerp(sx, tx, p), y = cy + ib_lerp(sy, ty, p);
        ib_fx_rect(&fx, x - BIG_DOT / 2, y - BIG_DOT / 2, BIG_DOT, BIG_DOT, BIG_DOT / 2, col, LV_OPA_COVER);
    }
}

static void banner_icon_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    draw_icon(&fx, fx.w / 2, fx.h / 2, 9, IB_P_ONE);
}

static void opa_cb(void *obj, int32_t v)
{
    lv_obj_set_style_opa(obj, (lv_opa_t)v, 0);
}

static void bg_opa_cb(void *obj, int32_t v)
{
    lv_obj_set_style_bg_opa(obj, (lv_opa_t)v, 0);
}

static void hide_done(lv_anim_t *a)
{
    (void)a;
    if (s_hiding) {
        lv_obj_add_flag(s_root, LV_OBJ_FLAG_HIDDEN);
        s_hiding = false;
    }
}

static void anim(lv_obj_t *obj, lv_anim_exec_xcb_t cb, int32_t from, int32_t to, uint32_t delay, uint32_t ms,
                 lv_anim_completed_cb_t done)
{
    lv_anim_delete(obj, cb);
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, obj);
    lv_anim_set_exec_cb(&a, cb);
    lv_anim_set_values(&a, from, to);
    lv_anim_set_delay(&a, delay);
    lv_anim_set_duration(&a, ms);
    lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
    if (done) lv_anim_set_completed_cb(&a, done);
    lv_anim_start(&a);
}

// 全屏出现:先 100 ms 把黑色背景铺满(此时下面的页面只是被压暗,没有内容叠在一起),再淡入通知内容。
static void full_enter(uint32_t now_ms)
{
    lv_obj_set_style_bg_opa(s_root, LV_OPA_TRANSP, 0);
    lv_obj_set_style_opa(s_full, LV_OPA_TRANSP, 0);
    anim(s_root, bg_opa_cb, LV_OPA_TRANSP, LV_OPA_COVER, 0, BACKDROP_MS, NULL);
    anim(s_full, opa_cb, LV_OPA_TRANSP, LV_OPA_COVER, BACKDROP_MS, CONTENT_IN_MS, NULL);
    s_show_ms = now_ms + BACKDROP_MS;   // 图标动画在背景铺满后才开始
}

static void apply_layout(void)
{
    uint32_t col = kind_color();
    if (s_is_banner) {
        lv_anim_delete(s_root, bg_opa_cb);
        lv_anim_delete(s_full, opa_cb);
        lv_obj_set_style_bg_opa(s_root, LV_OPA_TRANSP, 0);
        lv_obj_set_style_opa(s_banner, LV_OPA_COVER, 0);
        lv_obj_add_flag(s_full, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_banner, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_bg_color(s_banner, lv_color_mix(lv_color_hex(col), IB_C(IB_COLOR_BG), 70), 0);
        lv_obj_set_style_border_color(s_banner, lv_color_hex(col), 0);
        lv_obj_set_style_text_color(s_banner_text, lv_color_hex(col), 0);
        lv_obj_invalidate(s_banner_icon);
    } else {
        lv_anim_delete(s_banner, opa_cb);
        lv_obj_remove_flag(s_full, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_banner, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_text_color(s_title, lv_color_hex(col), 0);
    }
}

void ib_agent_create(lv_obj_t *screen)
{
    s_root = ib_box_create(screen, 0, 0, IB_UI_W, IB_UI_H);
    lv_obj_set_style_bg_color(s_root, IB_C(IB_COLOR_BG), 0);
    lv_obj_set_style_bg_opa(s_root, LV_OPA_TRANSP, 0);
    lv_obj_add_flag(s_root, LV_OBJ_FLAG_HIDDEN);

    s_full = ib_box_create(s_root, 0, 0, IB_UI_W, IB_UI_H);
    s_fx = ib_fx_create(s_full, 0, FX_Y, IB_UI_W, FX_H, fx_draw, NULL);
    s_title = ib_label_create(s_full, &lv_font_montserrat_28, IB_COLOR_TEXT, 222, IB_UI_W);
    s_source = ib_label_create(s_full, &lv_font_montserrat_20, IB_COLOR_TEXT, 262, IB_UI_W - 16);
    lv_label_set_text_static(s_source, s_source_text);
    s_hint = ib_caption_create(s_full, IB_COLOR_RING, 298, IB_UI_W, 1);
    lv_label_set_text_static(s_hint, "press any key");

    // 横幅只占左侧内容区,不遮挡右侧按键提示列。
    s_banner = ib_box_create(s_root, 8, BANNER_Y, IB_UI_CONTENT_W - 12, BANNER_H);
    lv_obj_set_style_radius(s_banner, BANNER_H / 2, 0);
    lv_obj_set_style_bg_opa(s_banner, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_banner, 1, 0);
    s_banner_icon = ib_fx_create(s_banner, 4, 2, 24, 24, banner_icon_draw, NULL);
    s_banner_text = lv_label_create(s_banner);
    lv_obj_set_style_text_font(s_banner_text, &lv_font_montserrat_14, 0);
    lv_obj_set_width(s_banner_text, IB_UI_CONTENT_W - 12 - 32 - 10);
    lv_label_set_long_mode(s_banner_text, LV_LABEL_LONG_MODE_DOTS);   // 太长时末尾显示省略号
    lv_obj_align(s_banner_text, LV_ALIGN_LEFT_MID, 32, 0);
    lv_label_set_text_static(s_banner_text, s_banner_buf);
    lv_obj_add_flag(s_banner, LV_OBJ_FLAG_HIDDEN);
}

void ib_agent_show(ib_ui_agent_t kind, const char *source, bool banner, uint32_t now_ms)
{
    size_t n = 0;
    for (; source && source[n] && n + 1 < sizeof(s_source_text); n++) {
        char ch = source[n];
        s_source_text[n] = (ch >= 0x20 && ch < 0x7F) ? ch : '?';
    }
    s_source_text[n] = '\0';
    bool was_visible = s_visible && !s_hiding;
    bool was_banner = s_is_banner;
    s_kind = kind;
    if (kind == IB_UI_AGENT_INPUT) lv_obj_remove_flag(s_hint, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_hint, LV_OBJ_FLAG_HIDDEN);
    s_is_banner = banner;
    s_show_ms = now_ms;
    const char *title = kind == IB_UI_AGENT_DONE ? "DONE" : "YOUR TURN";
    lv_label_set_text_static(s_title, title);
    lv_label_set_text_static(s_source, s_source_text);
    // 横幅只放图标 + 来源名(图标已经表达 done / input);没有来源名时才显示标题。
    snprintf(s_banner_buf, sizeof(s_banner_buf), "%s", s_source_text[0] ? s_source_text : title);
    lv_label_set_text_static(s_banner_text, s_banner_buf);
    apply_layout();

    s_visible = true;
    s_hiding = false;
    lv_anim_delete(s_root, NULL);           // 取消可能正在进行的关闭动画
    lv_obj_remove_flag(s_root, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(s_root);
    if (banner) {
        if (!was_visible || !was_banner) {
            lv_obj_set_style_opa(s_banner, LV_OPA_TRANSP, 0);
            anim(s_banner, opa_cb, LV_OPA_TRANSP, LV_OPA_COVER, 0, BANNER_FADE_MS, NULL);
        }
    } else if (!was_visible || was_banner) {
        full_enter(now_ms);
    } else {
        // 已经全屏显示(新通知替换旧通知):背景保持不动,内容保证完全可见,只重播图标动画。
        lv_anim_delete(s_full, opa_cb);
        lv_obj_set_style_opa(s_full, LV_OPA_COVER, 0);
        lv_obj_set_style_bg_opa(s_root, LV_OPA_COVER, 0);
    }
    ib_agent_frame(now_ms);
}

void ib_agent_set_banner(bool banner, uint32_t now_ms)
{
    if (!s_visible || s_hiding || banner == s_is_banner) return;
    s_is_banner = banner;
    apply_layout();
    // 横幅 → 全屏时重播出现动画(先铺背景再淡入内容),让用户注意到它;全屏 → 横幅直接切换。
    if (!banner) full_enter(now_ms);
}

void ib_agent_hide(void)
{
    if (!s_visible) return;
    s_visible = false;
    s_hiding = true;
    if (s_is_banner) {
        anim(s_banner, opa_cb, lv_obj_get_style_opa(s_banner, 0), LV_OPA_TRANSP, 0, BANNER_FADE_MS, hide_done);
        return;
    }
    // 全屏:先淡出内容,再撤掉黑色背景,下面的页面最后才露出来。
    anim(s_full, opa_cb, lv_obj_get_style_opa(s_full, 0), LV_OPA_TRANSP, 0, CONTENT_OUT_MS, NULL);
    anim(s_root, bg_opa_cb, lv_obj_get_style_bg_opa(s_root, 0), LV_OPA_TRANSP, CONTENT_OUT_MS, BACKDROP_MS,
         hide_done);
}

bool ib_agent_covering(void)
{
    return s_visible && !s_is_banner && lv_obj_get_style_bg_opa(s_root, 0) == LV_OPA_COVER;
}

void ib_agent_frame(uint32_t now_ms)
{
    if (!s_visible) return;
    // 背景还没铺满时 s_show_ms 在未来:动画停在起点。
    uint32_t t = (int32_t)(now_ms - s_show_ms) > 0 ? now_ms - s_show_ms : 0;
    if (s_is_banner) {
        if (s_kind == IB_UI_AGENT_INPUT) {
            // 横幅里的 "!" 每 3 s 摇摆一次(1.4 s,±12°,首尾平滑)。
            uint32_t w = t % WIGGLE_EVERY_MS;
            int32_t env = w < WIGGLE_MS ? ib_sin10((int32_t)(w * 1800U / WIGGLE_MS)) : 0;
            s_tilt = (int32_t)((int64_t)120 * ib_sin10((int32_t)(w * 3600U / 350U)) / 32768 * env / 32768);
            lv_obj_invalidate(s_banner_icon);
        }
        return;
    }
    if (s_kind == IB_UI_AGENT_DONE) {
        if (t > DONE_STILL_MS) return;                          // 点阵拼好后保持静止
    } else {
        s_breath = ib_ease_in_out_sine(ib_breath(t, BREATH_MS));
    }
    lv_obj_invalidate(s_fx);
}
