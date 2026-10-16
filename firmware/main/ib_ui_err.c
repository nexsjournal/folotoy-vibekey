// main/ib_ui_err.c: ERR 页:失败。
//
// 红色 X(外围淡红圆环)进入时左右抖动 3 次(每次 60 ms,幅度逐渐减小),下方显示 Mac 下发的原因 msg
// (最多两行)。约 2 s 后由 ib_app 切回 IDLE。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define CX          IB_UI_CX            // 内容区中心(右侧留给按键提示列)
#define CY          104
#define SHAKES      3
#define SHAKE_MS    60
#define SHAKE_PX    9
#define INTRO_MS    200

static lv_obj_t *s_fx;
static lv_obj_t *s_text;
static int32_t s_dx;
static int32_t s_scale = IB_P_ONE;
static bool s_settled;

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    int32_t c = fx.w / 2 + s_dx;
    int32_t cy = fx.h / 2;
    lv_color_t red = IB_C(IB_COLOR_ERR);
    int32_t r = 46 * s_scale / IB_P_ONE, k = 18 * s_scale / IB_P_ONE;
    ib_fx_circle(&fx, c, cy, r, red, LV_OPA_10);
    ib_fx_ring(&fx, c, cy, r, 3, red, LV_OPA_60);
    ib_fx_line(&fx, c - k, cy - k, c + k, cy + k, 7, red, LV_OPA_COVER);
    ib_fx_line(&fx, c + k, cy - k, c - k, cy + k, 7, red, LV_OPA_COVER);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, CX - 70, CY - 60, 140, 120, fx_draw, NULL);
    s_text = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_TEXT, 200, IB_UI_CONTENT_W - 20);
    lv_label_set_long_mode(s_text, LV_LABEL_LONG_MODE_WRAP);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    lv_label_set_text(s_text, ctx->msg[0] ? ctx->msg : "Failed");
}

static void enter(const ib_ui_ctx_t *ctx)
{
    s_dx = 0;
    s_settled = false;
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    if (s_settled) return;
    uint32_t t = ctx->now_ms - ctx->enter_ms;
    s_scale = IB_P_ONE * 8 / 10 + ib_ease_out_cubic(ib_progress(ctx->now_ms, ctx->enter_ms, INTRO_MS)) / 5;
    // 每 60 ms 一次摆动:右、左、右…,幅度线性衰减。
    const uint32_t total = SHAKES * 2 * SHAKE_MS;
    if (t < total) {
        int32_t phase = (int32_t)(t * 1800U / SHAKE_MS);            // 每 60 ms 半个周期
        int32_t amp = SHAKE_PX * (int32_t)(total - t) / (int32_t)total;
        s_dx = amp * ib_sin10(phase) / 32768;
    } else {
        s_dx = 0;
        s_settled = t > INTRO_MS;
    }
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_err = { create, enter, update, frame };
