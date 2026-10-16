// main/ib_ui_offline.c: OFFLINE 页:Mac 未连接时的大字时钟。
//
// 布局(页面坐标):时间 Montserrat 48 @ y=58;日期 20 @ y=124;呼吸圆点(4 s 周期)@ y=176;
// "waiting for Mac" @ y=214。只有圆点逐帧重绘,时间文字每分钟由 ib_app 更新一次。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define DOT_PERIOD_MS 4000

static lv_obj_t *s_time;
static lv_obj_t *s_date;
static lv_obj_t *s_dot;
static int32_t s_breath;

static void dot_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    int32_t c = fx.w / 2;
    lv_color_t gray = IB_C(IB_COLOR_TEXT_DIM);
    // 外圈光晕随呼吸扩散,中心点亮度在 25%~90% 之间。
    (void)gray;
    // 不透明精确灰:外圈光晕随呼吸扩散并变暗,中心点在 0x20..0x68 之间明暗。
    ib_fx_circle(&fx, c, c, 6 + s_breath * 8 / IB_P_ONE, ib_gray(0x18 - s_breath * 0x10 / IB_P_ONE), LV_OPA_COVER);
    ib_fx_circle(&fx, c, c, 5, ib_gray(0x20 + s_breath * 0x48 / IB_P_ONE), LV_OPA_COVER);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_W, IB_UI_PAGE_H);
    s_time = ib_label_create(root, &lv_font_montserrat_48, IB_COLOR_TEXT, 58, IB_UI_W);
    s_date = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_TEXT_DIM, 124, IB_UI_W);
    s_dot = ib_fx_create(root, IB_UI_W / 2 - 16, 160, 32, 32, dot_draw, NULL);
    lv_obj_t *wait = ib_label_create(root, &lv_font_montserrat_14, IB_COLOR_TEXT_DIM, 214, IB_UI_W);
    lv_label_set_text_static(wait, "waiting for Mac");
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    lv_label_set_text(s_time, ctx->time[0] ? ctx->time : "--:--");
    lv_label_set_text(s_date, ctx->time[0] ? ctx->date : "");
}

static void enter(const ib_ui_ctx_t *ctx)
{
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    s_breath = ib_ease_in_out_sine(ib_breath(ctx->now_ms, DOT_PERIOD_MS));
    lv_obj_invalidate(s_dot);
}

const ib_ui_page_t ib_ui_page_offline = { create, enter, update, frame };
