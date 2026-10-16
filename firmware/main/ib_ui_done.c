// main/ib_ui_done.c: DONE 页:已输入。
//
// 时间线(从进入页面起):
//   0~300 ms    绿色圆环从 12 点方向顺时针画满
//   300~560 ms  对勾两段描边依次画出
//   520~1100 ms 12 个白色粒子从圆环向外迸散并淡出,圆环同时外扩一圈白色柔光
// 单色风格:绿色只用于圆环与对勾。
// 文字 "TYPED"(或 Mac 下发的 msg,转大写)在 250 ms 后淡入。约 1.2 s 后由 ib_app 切回 IDLE。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#include <ctype.h>

#define CX          IB_UI_CX            // 内容区中心(右侧留给按键提示列)
#define CY          104
#define RING_R      46
#define RING_MS     300
#define CHECK_T0    300
#define CHECK_MS    260
#define BURST_T0    520
#define BURST_MS    580
#define PARTICLES   12
#define TEXT_T0     250

static lv_obj_t *s_fx;
static lv_obj_t *s_text;
static char s_msg[IB_UI_TEXT_MAX];
static int32_t s_ring;      // 圆环进度 0..IB_P_ONE
static int32_t s_check;     // 对勾进度
static int32_t s_burst;     // 迸散进度
static uint8_t s_seed[PARTICLES];   // 每个粒子的速度抖动,进入页面时随机

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    int32_t cx = fx.w / 2, cy = fx.h / 2;
    lv_color_t green = IB_C(IB_COLOR_DONE);

    if (s_burst > 0 && s_burst < IB_P_ONE) {
        int32_t fade = IB_P_ONE - s_burst;
        // 不透明精确灰随进度变暗(白色加透明度在 RGB565 下会偏绿)。
        ib_fx_ring(&fx, cx, cy, RING_R + 4 + s_burst * 14 / IB_P_ONE, 4, ib_gray(0x30 * fade / IB_P_ONE),
                   LV_OPA_COVER);
        for (int i = 0; i < PARTICLES; i++) {
            int32_t ang = i * 3600 / PARTICLES + 150;
            int32_t dist = RING_R + 6 + s_burst * (18 + s_seed[i] % 10) / IB_P_ONE;   // 最远约 r=80,不越出内容区
            int32_t x = cx + (dist * ib_cos10(ang) >> 15);
            int32_t y = cy + (dist * ib_sin10(ang) >> 15);
            ib_fx_circle(&fx, x, y, 1 + 2 * fade / IB_P_ONE, ib_gray(0xC8 * fade / IB_P_ONE), LV_OPA_COVER);
        }
    }
    ib_fx_circle(&fx, cx, cy, RING_R, green, ib_opa_scale(24, s_ring));
    if (s_ring > 0) ib_fx_arc(&fx, cx, cy, RING_R, 5, 270, 270 + s_ring * 360 / IB_P_ONE, green, LV_OPA_COVER);

    if (s_check > 0) {
        // 对勾:P1 → P2(短边,占总长约 35%)→ P3。
        const int32_t x1 = cx - 20, y1 = cy + 1, x2 = cx - 6, y2 = cy + 15, x3 = cx + 22, y3 = cy - 14;
        const int32_t split = IB_P_ONE * 35 / 100;
        if (s_check <= split) {
            int32_t p = s_check * IB_P_ONE / split;
            ib_fx_line(&fx, x1, y1, ib_lerp(x1, x2, p), ib_lerp(y1, y2, p), 6, green, LV_OPA_COVER);
        } else {
            int32_t p = (s_check - split) * IB_P_ONE / (IB_P_ONE - split);
            ib_fx_line(&fx, x1, y1, x2, y2, 6, green, LV_OPA_COVER);
            ib_fx_line(&fx, x2, y2, ib_lerp(x2, x3, p), ib_lerp(y2, y3, p), 6, green, LV_OPA_COVER);
        }
    }
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, CY - 85, IB_UI_CONTENT_W, 170, fx_draw, NULL);
    s_text = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_TEXT, 210, IB_UI_CONTENT_W - 16);
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
    s_ring = s_check = s_burst = 0;
    for (int i = 0; i < PARTICLES; i++) s_seed[i] = (uint8_t)lv_rand(0, 255);
    lv_obj_set_style_text_opa(s_text, LV_OPA_TRANSP, 0);
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    uint32_t now = ctx->now_ms, t0 = ctx->enter_ms;
    int32_t burst = ib_progress(now, t0 + BURST_T0, BURST_MS);
    if (burst >= IB_P_ONE && s_burst >= IB_P_ONE) return;   // 动画结束后不再重绘
    s_ring = ib_ease_out_cubic(ib_progress(now, t0, RING_MS));
    s_check = ib_ease_out_cubic(ib_progress(now, t0 + CHECK_T0, CHECK_MS));
    s_burst = burst == 0 ? 0 : ib_ease_out_cubic(burst);
    if (burst >= IB_P_ONE) s_burst = IB_P_ONE;
    lv_obj_set_style_text_opa(s_text, ib_opa_scale(255, ib_progress(now, t0 + TEXT_T0, 250)), 0);
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_done = { create, enter, update, frame };
