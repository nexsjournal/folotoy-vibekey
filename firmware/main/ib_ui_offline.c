// main/ib_ui_offline.c: OFFLINE 页:Mac 未连接时的点阵时钟(docs/device-ui.md「OFFLINE」;全宽,无提示列)。
//
// 时钟用与其它页面同一种 5x5 圆点画成 5x7 点阵数字(4 位 + 冒号正好 25 列,铺满 200 px,居中),
// 冒号 1 s 一闪表示"活着";下方日期(12 px 大写加字距)和 "waiting for Mac"(12 px 深灰)。
// 只有冒号逐帧变化:每帧只 invalidate 冒号那一小块;时间文字每分钟由 ib_app 更新一次。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define CLOCK_X0    24                      // 第 0 列点心 x(全宽:24 + 8c,c = 0..24)
#define CLOCK_Y     (88 - IB_UI_BAR_H)      // 点阵控件顶部(行 8..14 → 屏幕 y 92..140)
#define CLOCK_H     56
#define COLON_COL   12
#define DATE_CY     (172 - IB_UI_BAR_H)
#define WAIT_CY     (240 - IB_UI_BAR_H)
#define BLINK_MS    1000

// 5x7 数字字模(每行 5 位,高位在左)。
static const uint8_t DIGITS[10][7] = {
    { 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E }, { 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E },
    { 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F }, { 0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E },
    { 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02 }, { 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E },
    { 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E }, { 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
    { 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E }, { 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C },
};
// 4 位数字的起始列(冒号在第 12 列)。
static const int8_t DIGIT_COL[4] = { 0, 6, 14, 20 };

static lv_obj_t *s_clock;
static lv_obj_t *s_date;
static char s_time[8];
static int32_t s_colon;                     // 冒号亮度 0..IB_P_ONE

static int32_t dot_x(int32_t c)
{
    return CLOCK_X0 + c * IB_DOTS_PITCH;
}

static int32_t dot_y(int32_t r)
{
    return 4 + r * IB_DOTS_PITCH;           // 控件内:第 0 行点心 y = 4
}

static void clock_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    lv_color_t on = IB_C(IB_COLOR_TEXT);
    // "HH:MM";未知时间(--:--)只画两条短横。
    int k = 0;
    for (const char *p = s_time; *p && k < 4; p++) {
        if (*p == ':') continue;
        int8_t c0 = DIGIT_COL[k++];
        if (*p < '0' || *p > '9') {
            for (int c = 1; c < 4; c++) ib_dots_dot(&fx, dot_x(c0 + c), dot_y(3), ib_gray(0x50), 0);
            continue;
        }
        const uint8_t *g = DIGITS[*p - '0'];
        for (int r = 0; r < 7; r++) {
            for (int c = 0; c < 5; c++) {
                if (g[r] & (0x10 >> c)) ib_dots_dot(&fx, dot_x(c0 + c), dot_y(r), on, 0);
            }
        }
    }
    lv_color_t colon = ib_gray_lerp(0x30, 0xF0, s_colon);
    ib_dots_dot(&fx, dot_x(COLON_COL), dot_y(2), colon, 0);
    ib_dots_dot(&fx, dot_x(COLON_COL), dot_y(4), colon, 0);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_W, IB_UI_PAGE_H);
    s_clock = ib_fx_create(root, 0, CLOCK_Y, IB_UI_W, CLOCK_H, clock_draw, NULL);
    s_date = ib_caption_create(root, IB_COLOR_TEXT_DIM, ib_font_top(&lv_font_montserrat_12, DATE_CY), IB_UI_W, 2);
    lv_obj_t *wait = ib_caption_create(root, IB_COLOR_RING, ib_font_top(&lv_font_montserrat_12, WAIT_CY), IB_UI_W, 1);
    lv_label_set_text_static(wait, "waiting for Mac");
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    lv_snprintf(s_time, sizeof(s_time), "%s", ctx->time[0] ? ctx->time : "--:--");
    lv_label_set_text(s_date, ctx->time[0] ? ctx->date : "");
    lv_obj_invalidate(s_clock);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    // 冒号:亮 ↔ 暗的柔和正弦,1 s 一个周期。
    s_colon = IB_P_ONE - ib_ease_in_out_sine(ib_breath(ctx->now_ms, BLINK_MS));
    lv_area_t a;
    lv_obj_get_coords(s_clock, &a);
    int32_t x = a.x1 + dot_x(COLON_COL);
    lv_area_t colon = { x - 4, a.y1, x + 4, a.y2 };
    lv_obj_invalidate_area(s_clock, &colon);
}

const ib_ui_page_t ib_ui_page_offline = { create, enter, update, frame };
