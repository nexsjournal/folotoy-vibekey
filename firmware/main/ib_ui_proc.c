// main/ib_ui_proc.c: PROC 页:识别 / LLM 处理中。
//
// 8 个白色小圆点沿半径 46 的圆周旋转(1.2 s 一圈),头部最大最亮,后面的点依次变小变淡形成拖尾;
// 下方 "THINKING" 文字透明度以 1.2 秒周期脉动。进入页面时圆周半径从 0.85 倍缓动到 1 倍。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define CX          IB_UI_CX            // 内容区中心(右侧留给按键提示列)
#define CY          104
#define ORBIT_R     46
#define DOTS        8
#define SPIN_MS     1200
#define TRAIL_DEG   26          // 相邻拖尾点的角度间隔
#define PULSE_MS    1200
#define INTRO_MS    320

static lv_obj_t *s_fx;
static lv_obj_t *s_text;
static int32_t s_head = 0;          // 头部角度(0.1 度)
static int32_t s_radius = ORBIT_R;

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    int32_t c = fx.w / 2;
    // 全部用不透明精确灰:轨道 #181818,头部柔光 #202020,拖尾点由白渐暗。
    ib_fx_ring(&fx, c, c, s_radius, 1, IB_C(IB_COLOR_SURFACE), LV_OPA_COVER);
    int32_t hx = c + (s_radius * ib_cos10(s_head) >> 15);
    int32_t hy = c + (s_radius * ib_sin10(s_head) >> 15);
    ib_fx_circle(&fx, hx, hy, 11, ib_gray(0x20), LV_OPA_COVER);
    for (int k = DOTS - 1; k >= 0; k--) {
        int32_t ang = s_head - k * TRAIL_DEG * 10;
        int32_t x = c + (s_radius * ib_cos10(ang) >> 15);
        int32_t y = c + (s_radius * ib_sin10(ang) >> 15);
        int32_t r = 6 - k * 4 / DOTS;                       // 6 → 3 px
        ib_fx_circle(&fx, x, y, r, ib_gray((IB_COLOR_TEXT & 0xFF) - k * 200 / DOTS), LV_OPA_COVER);
    }
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, CX - 64, CY - 64, 128, 128, fx_draw, NULL);
    s_text = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_TEXT, 196, IB_UI_CONTENT_W);
    lv_label_set_text_static(s_text, "THINKING");
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    (void)ctx;      // 单色风格:所有模式都用白 / 灰
    lv_obj_invalidate(s_fx);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    uint32_t t = ctx->now_ms - ctx->enter_ms;
    s_head = (int32_t)((t % SPIN_MS) * 3600U / SPIN_MS) - 900;
    int32_t intro = ib_ease_out_cubic(ib_progress(ctx->now_ms, ctx->enter_ms, INTRO_MS));
    s_radius = ORBIT_R * 85 / 100 + ORBIT_R * 15 / 100 * intro / IB_P_ONE;
    int32_t pulse = ib_breath(ctx->now_ms - ctx->enter_ms, PULSE_MS);
    lv_obj_set_style_text_opa(s_text, ib_opa_scale(255, IB_P_ONE - pulse * 6 / 10), 0);
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_proc = { create, enter, update, frame };
