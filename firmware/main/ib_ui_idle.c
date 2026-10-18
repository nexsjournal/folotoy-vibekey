// main/ib_ui_idle.c: IDLE 页:当前模式(docs/device-ui.md「IDLE」)。
//
// 一屏只有"一个点阵图形 + 一行字":
//   字形    当前模式的点阵图标(dict = 麦克风、tr = 两个对话气泡、sub = CC 框,ib_ui_dots),
//           浅灰底色;每 4 s 一道扫描光自上而下掠过,经过的点变白并略微放大,让静止页面"活着"
//   模式名  Montserrat 20,中心 y=220
// 操作提示由右侧按键提示列承担。切换模式:点阵从旧字形重排成新字形(从左到右"重新像素化"),
// 模式名纵向翻牌(旧的向上 / 下翻出淡出,新的从另一侧翻入)。按下 OK 时由 REC 页接着这一帧把点重排成一条线。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define NAME_CY     (220 - IB_UI_BAR_H)
#define FLIP_MS     400
#define FLIP_PX     24
#define OUT_MS      140                     // 旧模式名 0..140 ms 翻出
#define IN_T0       140                     // 新模式名 140..360 ms 翻入(旧的完全消失后,两行字不会叠在一起)
#define IN_MS       220
#define SCAN_EVERY_MS 4000
#define SCAN_MS     800                     // 扫描光自上而下用时
#define SCAN_ROW0   6                       // 扫描光起止行(覆盖字形 8..17 行)
#define SCAN_ROW1   20

static lv_obj_t *s_fx;
static lv_obj_t *s_names[2];
static int s_front;
static int s_dir;                           // +1:下一个模式(旧名字向上翻出);-1:上一个
static ib_ui_mode_t s_mode;
static int32_t s_scan = -1;                 // 扫描光所在行(x16);-1 表示没有扫描

static const char *const MODE_NAMES[IB_UI_MODE_COUNT] = { "DICTATE", "TRANSLATE", "SUBTITLES" };
static const ib_dots_glyph_t MODE_GLYPHS[IB_UI_MODE_COUNT] = {
    [IB_UI_MODE_DICT] = IB_DOTS_MIC, [IB_UI_MODE_TR] = IB_DOTS_TR, [IB_UI_MODE_SUB] = IB_DOTS_CC,
};

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    uint32_t now = lv_tick_get();
    if (!ib_dots_settled(now) || s_scan < 0) {
        ib_dots_draw(&fx, now, 0);
        return;
    }
    // 扫描光:离光带越近越亮(浅灰 → 白),正中的一行放大 1 px。
    const ib_dots_t *g = ib_dots_current();
    for (int i = 0; i < g->n; i++) {
        const ib_dot_t *d = &g->d[i];
        int32_t dist = LV_ABS(d->r * 16 - s_scan);               // x16
        int32_t glow = dist < 24 ? (24 - dist) * IB_P_ONE / 24 : 0;
        lv_color_t c = ib_gray_lerp(0xC8, 0xF0, glow);
        ib_dots_dot(&fx, ib_dots_x(d->c), ib_dots_y(d->r), c, dist < 8 ? 1 : 0);
    }
}

static void target_for(ib_ui_mode_t mode, ib_dots_t *out)
{
    ib_dots_glyph(out, MODE_GLYPHS[mode], IB_DOT_SOFT);
}

static void name_place(lv_obj_t *l, int32_t dy, lv_opa_t opa)
{
    lv_obj_set_style_translate_y(l, dy, 0);
    lv_obj_set_style_opa(l, opa, 0);
}

// 模式名翻牌:t 为 0..FLIP_MS 的毫秒。
static void flip_cb(lv_anim_t *a, int32_t t)
{
    (void)a;
    lv_obj_t *in = s_names[s_front], *out = s_names[1 - s_front];
    int32_t po = IB_P_ONE - ib_ease_out_cubic(IB_P_ONE - ib_progress((uint32_t)t, 0, OUT_MS));   // ease-in
    name_place(out, -s_dir * FLIP_PX * po / IB_P_ONE, ib_opa_scale(255, IB_P_ONE - po));
    int32_t pi = ib_ease_out_cubic(ib_progress((uint32_t)t, IN_T0, IN_MS));
    name_place(in, s_dir * FLIP_PX * (IB_P_ONE - pi) / IB_P_ONE, ib_opa_scale(255, pi));
}

static void snap_name(ib_ui_mode_t mode)
{
    lv_anim_delete(&s_names, NULL);
    lv_label_set_text_static(s_names[s_front], MODE_NAMES[mode]);
    name_place(s_names[s_front], 0, LV_OPA_COVER);
    name_place(s_names[1 - s_front], 0, LV_OPA_TRANSP);
}

static void flip_name(ib_ui_mode_t mode)
{
    s_front = 1 - s_front;
    lv_label_set_text_static(s_names[s_front], MODE_NAMES[mode]);
    lv_anim_delete(&s_names, NULL);
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, &s_names);         // 仅作为动画的唯一标识
    lv_anim_set_custom_exec_cb(&a, flip_cb);
    lv_anim_set_values(&a, 0, FLIP_MS);
    lv_anim_set_duration(&a, FLIP_MS);
    lv_anim_set_path_cb(&a, lv_anim_path_linear);
    lv_anim_start(&a);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, IB_DOTS_BOX_Y, IB_UI_CONTENT_W, IB_DOTS_BOX_H, fx_draw, NULL);
    for (int i = 0; i < 2; i++) {
        s_names[i] = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_TEXT,
                                     ib_font_top(&lv_font_montserrat_20, NAME_CY), IB_UI_CONTENT_W);
    }
    return root;
}

static void enter(const ib_ui_ctx_t *ctx)
{
    s_mode = ctx->mode;
    ib_dots_t g;
    target_for(s_mode, &g);
    ib_dots_enter(ctx, &g);
    snap_name(s_mode);
}

static void update(const ib_ui_ctx_t *ctx)
{
    if (ctx->mode == s_mode) return;
    // 循环顺序 dict → tr → sub:前进时旧名字向上翻出,后退时向下。
    s_dir = ctx->mode == (ib_ui_mode_t)((s_mode + 1) % IB_UI_MODE_COUNT) ? 1 : -1;
    s_mode = ctx->mode;
    ib_dots_t g;
    target_for(s_mode, &g);
    ib_dots_show(&g, true, false, ctx->now_ms);
    flip_name(s_mode);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    // 扫描光:以本页进入(或上次重排结束)为起点,每 4 s 一次,800 ms 内从第 6 行扫到第 20 行。
    uint32_t since = ctx->now_ms - ib_dots_settle_ms();
    bool was_scanning = s_scan >= 0;
    if (ib_dots_settled(ctx->now_ms) && since >= SCAN_EVERY_MS && since % SCAN_EVERY_MS < SCAN_MS) {
        int32_t p = ib_ease_in_out_sine(ib_progress(since % SCAN_EVERY_MS, 0, SCAN_MS));
        s_scan = (SCAN_ROW0 * 16) + (SCAN_ROW1 - SCAN_ROW0) * 16 * p / IB_P_ONE;
    } else {
        s_scan = -1;
    }
    // 重排、扫描进行中,或扫描刚结束(要擦掉最后一帧的光)时才重绘。
    if (!ib_dots_settled(ctx->now_ms) || s_scan >= 0 || was_scanning ||
        ctx->now_ms - ib_dots_settle_ms() < 100) {
        lv_obj_invalidate(s_fx);
    }
}

const ib_ui_page_t ib_ui_page_idle = { create, enter, update, frame };
