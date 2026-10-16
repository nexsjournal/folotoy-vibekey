// main/ib_ui_sub.c: SUB 页:字幕运行中(状态栏左侧由 ib_ui_statusbar 显示 LIVE 徽章)。
//
// 布局(页面坐标,只用左侧内容区):
//   均衡器  一排 16 根竖条(宽 8、间隔 4,水平居中),底边 y=168,最高 120 px;由电平驱动,
//           每根条叠加不同频率与相位的正弦抖动;条顶有白色峰值帽:被顶起后停 300 ms,再以 60 px/s 下落
//   应用名  Montserrat 20 @ y=192(msg)
// "STOP" 等操作提示由右侧按键提示列(Mac 下发)显示。
// 单色风格:条身为随高度变亮的不透明精确灰,峰值帽为白色(不用渐变,渐变的中间色在 RGB565 下会偏色)。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define BARS        16
#define BAR_W       8
#define BAR_GAP     4
#define BAR_MAXH    120
#define BAR_MINH    4
#define FX_Y        40
#define FX_H        136
#define BASE        (FX_H - 4)  // 条底边(控件坐标)
#define CAP_H       3
#define CAP_GAP     3
#define CAP_HOLD_MS 300
#define CAP_FALL_PX_PER_S 60
#define INTRO_MS    400

typedef struct {
    int32_t h;          // 当前高度(x16)
    int32_t cap;        // 峰值帽高度(x16)
    uint32_t cap_t;     // 峰值帽最近一次被顶起的时刻
} bar_t;

static lv_obj_t *s_fx;
static lv_obj_t *s_app;
static bar_t s_bars[BARS];
static uint32_t s_last_ms;

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    const int32_t total_w = BARS * BAR_W + (BARS - 1) * BAR_GAP;
    int32_t x0 = (fx.w - total_w) / 2;
    lv_color_t cap_color = IB_C(IB_COLOR_TEXT);
    for (int i = 0; i < BARS; i++) {
        const bar_t *b = &s_bars[i];
        int32_t x = x0 + i * (BAR_W + BAR_GAP);
        int32_t h = b->h / 16;
        int32_t cap = b->cap / 16;
        ib_fx_rect(&fx, x, BASE - BAR_MAXH, BAR_W, BAR_MAXH, BAR_W / 2, IB_C(IB_COLOR_SURFACE), LV_OPA_COVER);
        ib_fx_rect(&fx, x, BASE - h, BAR_W, h, BAR_W / 2, ib_gray(0x80 + h * 0x60 / BAR_MAXH), LV_OPA_COVER);
        ib_fx_rect(&fx, x, BASE - cap - CAP_GAP - CAP_H, BAR_W, CAP_H, 1, cap_color, LV_OPA_COVER);
    }
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, FX_Y, IB_UI_CONTENT_W, FX_H, fx_draw, NULL);
    s_app = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_TEXT, FX_Y + FX_H + 16, IB_UI_CONTENT_W - 16);
    lv_label_set_long_mode(s_app, LV_LABEL_LONG_MODE_DOTS);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    lv_label_set_text(s_app, ctx->msg);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    for (int i = 0; i < BARS; i++) {
        s_bars[i].h = BAR_MINH * 16;
        s_bars[i].cap = BAR_MINH * 16;
        s_bars[i].cap_t = ctx->enter_ms;
    }
    s_last_ms = ctx->enter_ms;
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    uint32_t now = ctx->now_ms;
    uint32_t dt = now - s_last_ms;
    s_last_ms = now;
    int32_t lvl = ctx->level_smooth;    // 0..1000
    int32_t intro = ib_ease_out_cubic(ib_progress(now, ctx->enter_ms, INTRO_MS));

    for (int i = 0; i < BARS; i++) {
        bar_t *b = &s_bars[i];
        // 每根条有自己的频率(约 0.6~1.6 Hz)与相位,中间的条略高,整体呈自然的山形。
        int32_t speed = 216 + (i * 37) % 360;               // 0.1 度 / 10 ms
        int32_t phase = (int32_t)(now / 10U) * speed / 10 + i * 731;
        int32_t wobble = (ib_sin10(phase) + 32768) * 100 / 65536;    // 0..100
        int32_t center = 100 - LV_ABS(2 * i - (BARS - 1)) * 30 / (BARS - 1);   // 70..100 %
        int32_t shape = (45 + wobble * 55 / 100) * center / 100;
        int32_t target = BAR_MINH + (lvl * BAR_MAXH / 1000) * shape / 100 * intro / IB_P_ONE;
        target += wobble * 6 / 100;                                   // 静音时也有轻微律动
        if (target > BAR_MAXH) target = BAR_MAXH;
        b->h += (target * 16 - b->h) * 35 / 100;

        if (b->h >= b->cap) {
            b->cap = b->h;
            b->cap_t = now;
        } else if (now - b->cap_t > CAP_HOLD_MS) {
            b->cap -= (int32_t)(CAP_FALL_PX_PER_S * 16 * dt / 1000U);
            if (b->cap < b->h) b->cap = b->h;
        }
    }
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_sub = { create, enter, update, frame };
