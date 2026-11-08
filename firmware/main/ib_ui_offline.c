// main/ib_ui_offline.c: OFFLINE 页:Mac 未连接时的点阵时钟(docs/device-ui.md「OFFLINE」;全宽,无提示列)。
//
// 猫咪像素背景从 Flash 直接绘制，时钟和日期覆盖在底部深色区域。
// 只有冒号逐帧变化:每帧只 invalidate 冒号那一小块;时间文字每分钟由 ib_app 更新一次。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"
#include "ib_protocol.h"
#include "ib_wallpaper.h"

#define CLOCK_PITCH 6
#define CLOCK_X0    ((IB_UI_W - 24 * CLOCK_PITCH) / 2)
#define CLOCK_Y     253
#define CLOCK_H     (7 * CLOCK_PITCH)
#define COLON_COL   12
#define DATE_CY     301
#define WAIT_CY     313
#define BLINK_MS    1000

static const _Alignas(4) uint8_t OFFLINE_ART[] = {
#include "ib_offline_art.inc"
};
_Static_assert(sizeof(OFFLINE_ART) == IB_UI_W * IB_UI_H * 2, "Offline artwork size mismatch");
static const lv_image_dsc_t OFFLINE_IMAGE = {
    .header = { .magic = LV_IMAGE_HEADER_MAGIC, .cf = LV_COLOR_FORMAT_RGB565,
                .w = IB_UI_W, .h = IB_UI_H, .stride = IB_UI_W * 2 },
    .data_size = sizeof(OFFLINE_ART),
    .data = OFFLINE_ART,
};
static lv_image_dsc_t s_wallpaper_image;

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
static lv_obj_t *s_hint;
static char s_time[8];
static int32_t s_colon;                     // 冒号亮度 0..IB_P_ONE

static int32_t dot_x(int32_t c)
{
    return CLOCK_X0 + c * CLOCK_PITCH;
}

static int32_t dot_y(int32_t r)
{
    return CLOCK_PITCH / 2 + r * CLOCK_PITCH;
}

static void clock_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    lv_color_t on = IB_C(IB_COLOR_MATRIX_SOFT);
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
    lv_color_t colon = lv_color_mix(IB_C(IB_COLOR_MATRIX_SOFT), IB_C(IB_COLOR_MATRIX_FRAME),
                                     (uint8_t)(s_colon * 255 / IB_P_ONE));
    ib_dots_dot(&fx, dot_x(COLON_COL), dot_y(2), colon, 0);
    ib_dots_dot(&fx, dot_x(COLON_COL), dot_y(4), colon, 0);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_W, IB_UI_H);
    lv_obj_t *background = lv_image_create(root);
    const uint8_t *pixels = ib_wallpaper_pixels();
    if (pixels) {
        s_wallpaper_image = OFFLINE_IMAGE;
        s_wallpaper_image.data_size = IB_WALLPAPER_MAX_BYTES;
        s_wallpaper_image.data = pixels;
        lv_image_set_src(background, &s_wallpaper_image);
    } else {
        lv_image_set_src(background, &OFFLINE_IMAGE);
    }
    lv_obj_t *title = ib_label_create(root, &ib_terminal_font_14, IB_COLOR_MATRIX_SOFT, 0, IB_UI_W - 20);
    lv_obj_set_style_text_align(title, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_align(title, LV_ALIGN_TOP_LEFT, 10, IB_UI_BAR_H + 2);
    lv_label_set_text_static(title, "> OFFLINE_");
    s_clock = ib_fx_create(root, 0, CLOCK_Y, IB_UI_W, CLOCK_H, clock_draw, NULL);
    s_date = ib_caption_create(root, IB_COLOR_TEXT_MID, ib_font_top(&lv_font_montserrat_12, DATE_CY), IB_UI_W, 2);
    s_hint = ib_caption_create(root, IB_COLOR_TEXT_MID, ib_font_top(&lv_font_montserrat_12, WAIT_CY), IB_UI_W, 1);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    lv_snprintf(s_time, sizeof(s_time), "%s", ctx->time[0] ? ctx->time : "--:--");
    lv_label_set_text(s_date, ctx->time[0] ? ctx->date : "");
    lv_label_set_text_static(s_hint, ctx->offline_hint[0] ? ctx->offline_hint : "WAITING FOR MAC");
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
