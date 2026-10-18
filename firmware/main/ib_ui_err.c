// main/ib_ui_err.c: ERR 页:失败(docs/device-ui.md「ERR」)。
//
// 点重排成红色的叉(ib_ui_dots),同时整体左右抖动 3 次(每半周期 60 ms,幅度衰减);下方显示 Mac 下发的原因 msg
// (Montserrat 20,最多两行)。约 2 s 后由 ib_app 切回 IDLE,叉再重排回模式字形。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define TEXT_CY     (220 - IB_UI_BAR_H)
#define SHAKES      3
#define SHAKE_MS    60
#define SHAKE_PX    6

static lv_obj_t *s_fx;
static lv_obj_t *s_text;
static int32_t s_dx;
static bool s_still;

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    ib_dots_draw(&fx, lv_tick_get(), s_dx);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, IB_DOTS_BOX_Y, IB_UI_CONTENT_W, IB_DOTS_BOX_H, fx_draw, NULL);
    s_text = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_TEXT, ib_font_top(&lv_font_montserrat_20, TEXT_CY),
                             IB_UI_CONTENT_W - 20);
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    lv_label_set_text(s_text, ctx->msg[0] ? ctx->msg : "Failed");
}

static void enter(const ib_ui_ctx_t *ctx)
{
    ib_dots_t x;
    ib_dots_glyph(&x, IB_DOTS_X, IB_DOT_ERR);
    ib_dots_enter(ctx, &x);
    s_dx = 0;
    s_still = false;
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    if (s_still) return;
    uint32_t t = ctx->now_ms - ctx->enter_ms;
    const uint32_t total = SHAKES * 2 * SHAKE_MS;
    if (t < total) {
        int32_t amp = SHAKE_PX * (int32_t)(total - t) / (int32_t)total;
        s_dx = amp * ib_sin10((int32_t)(t * 1800U / SHAKE_MS)) / 32768;
    } else {
        s_dx = 0;
        s_still = ib_dots_settled(ctx->now_ms);
    }
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_err = { create, enter, update, frame };
