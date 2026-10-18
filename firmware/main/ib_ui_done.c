// main/ib_ui_done.c: DONE 页:已输入(docs/device-ui.md「DONE」)。
//
// 只是一个状态,不是庆祝画面:处理中的那条线重排回当前模式的点阵字形(ib_ui_dots),点在飞行中变成完成绿,
// 落地后 600 ms 内慢慢褪回 IDLE 的浅灰——约 1.2 s 后 ib_app 切回 IDLE 时画面已经和 IDLE 一样,无缝衔接。
// 下方一行状态字(绿色):TYPED,或 Mac 下发的 msg(COPIED / NOT TRANSLATED / NOT POLISHED,转大写),
// 250 ms 起淡入并从下方 6 px 上移到位。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#include <ctype.h>

#define TEXT_CY     (220 - IB_UI_BAR_H)
#define TEXT_T0     250
#define TEXT_MS     250
#define TEXT_RISE   6
#define FADE_MS     600                 // 落地后由绿褪回浅灰

static lv_obj_t *s_fx;
static lv_obj_t *s_text;
static char s_msg[IB_UI_TEXT_MAX];
static int32_t s_fade = -1;             // 落地后的褪色进度;-1 表示还在重排
static bool s_still;
static ib_ui_mode_t s_mode;

static const ib_dots_glyph_t MODE_GLYPHS[IB_UI_MODE_COUNT] = {
    [IB_UI_MODE_DICT] = IB_DOTS_MIC, [IB_UI_MODE_TR] = IB_DOTS_TR, [IB_UI_MODE_SUB] = IB_DOTS_CC,
};

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    uint32_t now = lv_tick_get();
    if (!ib_dots_settled(now) || s_fade < 0) {
        ib_dots_draw(&fx, now, 0);
        return;
    }
    lv_color_t c = lv_color_mix(ib_gray(0xC8), IB_C(IB_COLOR_DONE), (uint8_t)(s_fade * 255 / IB_P_ONE));
    if (s_fade >= IB_P_ONE) c = ib_gray(0xC8);                  // 终点用精确灰
    const ib_dots_t *g = ib_dots_current();
    for (int i = 0; i < g->n; i++) ib_dots_dot(&fx, ib_dots_x(g->d[i].c), ib_dots_y(g->d[i].r), c, 0);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, IB_DOTS_BOX_Y, IB_UI_CONTENT_W, IB_DOTS_BOX_H, fx_draw, NULL);
    s_text = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_DONE, ib_font_top(&lv_font_montserrat_20, TEXT_CY),
                             IB_UI_CONTENT_W - 16);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    size_t n = 0;
    const char *src = ctx->msg[0] ? ctx->msg : "TYPED";
    for (; src[n] && n + 1 < sizeof(s_msg); n++) s_msg[n] = (char)toupper((unsigned char)src[n]);
    s_msg[n] = '\0';
    lv_label_set_text_static(s_text, s_msg);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    s_mode = ctx->mode < IB_UI_MODE_COUNT ? ctx->mode : IB_UI_MODE_DICT;
    ib_dots_t g;
    ib_dots_glyph(&g, MODE_GLYPHS[s_mode], IB_DOT_DONE);
    ib_dots_enter(ctx, &g);
    s_fade = -1;
    s_still = false;
    lv_obj_set_style_text_opa(s_text, LV_OPA_TRANSP, 0);
    lv_obj_set_style_translate_y(s_text, TEXT_RISE, 0);
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    if (s_still) return;                                        // 褪色结束后不再重绘
    uint32_t now = ctx->now_ms;
    int32_t text = ib_progress(now, ctx->enter_ms + TEXT_T0, TEXT_MS);
    lv_obj_set_style_text_opa(s_text, ib_opa_scale(255, text), 0);
    lv_obj_set_style_translate_y(s_text, TEXT_RISE - TEXT_RISE * ib_ease_out_cubic(text) / IB_P_ONE, 0);
    if (ib_dots_settled(now)) {
        s_fade = ib_ease_in_out_sine(ib_progress(now, ib_dots_settle_ms(), FADE_MS));
        s_still = s_fade >= IB_P_ONE && text >= IB_P_ONE;
        if (s_fade >= IB_P_ONE && ib_dots_current()->d[0].color != IB_DOT_SOFT) {
            // 褪色结束:当前图案换成 IDLE 的浅灰字形,切回 IDLE 时不会从绿色再重排一次。
            ib_dots_t g;
            ib_dots_glyph(&g, MODE_GLYPHS[s_mode], IB_DOT_SOFT);
            ib_dots_show(&g, false, false, now);
        }
    }
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_done = { create, enter, update, frame };
