// main/ib_ui_rec.c: REC 页:录音中。
//
// 一个 内容区宽 x 240 的自绘控件(中心 (IB_UI_CX, 120)),由里到外:
//   - 极淡的灰色径向光晕(2 层不透明精确灰同心圆),进入页面时 400 ms 渐亮
//   - 3 圈同心波纹:每 900 ms 从中心发射一圈,2.7 s 内向外扩散并淡出,扩散距离随电平放大
//   - 32 根放射状电平条:长度 = 电平 x 随机抖动,每帧向目标值靠近 35%,越长越亮(精确灰 → 白)
//   - 红色实心圆(直径约 56 px),随电平轻微鼓动;翻译听写模式下外圈加浅灰细描边
// 单色风格:红色只用于中心圆点与波纹。
// 左上角(状态栏计时下方):翻译听写模式显示小字 "TRANSLATE",不靠颜色也能区分模式。
// 底部小字(14 号灰色):OK 仍按住时 "RELEASE OK"(按住说话),已松开时 "OK TO STOP"(切换模式);
// 它只是对右侧 OK 提示图标的补充,取消等其它键的作用见右侧按键提示列(Mac 下发)。
// 逐帧只计算几何参数,绘制回调只负责画(LVGL 会对每个刷新分块各调用一次绘制回调)。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define CX          IB_UI_CX            // 内容区中心(右侧留给按键提示列)
#define CY          120
#define BARS        32
#define BAR_R0      40          // 电平条内端半径
#define BAR_MAX     36          // 电平条最大长度(外端最远 r=76,留在内容区内)
#define BAR_MIN     3
#define CORE_R      28
#define RIPPLES     3
#define RIPPLE_EVERY_MS 900
#define RIPPLE_LIFE_MS  (RIPPLE_EVERY_MS * RIPPLES)
#define GLOW_IN_MS  400

static lv_obj_t *s_fx;
static lv_obj_t *s_hint;
static lv_obj_t *s_mode_caption;
static bool s_translate;
static int32_t s_bar_len[BARS];     // 电平条当前长度(x16 定点)
static int32_t s_ripple_r[RIPPLES];
static lv_opa_t s_ripple_opa[RIPPLES];
static int32_t s_core_r = CORE_R;
static int32_t s_glow = 0;          // 0..IB_P_ONE

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    lv_color_t red = IB_C(IB_COLOR_REC);

    // 径向光晕:两层不透明精确灰(白色加透明度在 RGB565 下会偏绿)。
    // 外层几乎贴近黑色(#080808),内层大半被电平条覆盖,整体只是极淡的一圈。
    ib_fx_circle(&fx, CX, CY, 80, ib_gray(0x08 * s_glow / IB_P_ONE), LV_OPA_COVER);
    ib_fx_circle(&fx, CX, CY, 50, ib_gray(0x10 * s_glow / IB_P_ONE), LV_OPA_COVER);

    for (int i = 0; i < RIPPLES; i++) {
        if (s_ripple_opa[i] > 2) ib_fx_ring(&fx, CX, CY, s_ripple_r[i], 2, red, s_ripple_opa[i]);
    }

    for (int i = 0; i < BARS; i++) {
        int32_t len = s_bar_len[i] / 16;
        int32_t ang = i * 3600 / BARS - 900;
        int32_t c = ib_cos10(ang), s = ib_sin10(ang);
        int32_t x1 = CX + (BAR_R0 * c >> 15), y1 = CY + (BAR_R0 * s >> 15);
        int32_t x2 = CX + ((BAR_R0 + len) * c >> 15), y2 = CY + ((BAR_R0 + len) * s >> 15);
        // 越长越亮。
        ib_fx_line(&fx, x1, y1, x2, y2, 3, ib_gray(0x50 + len * 0xA0 / BAR_MAX), LV_OPA_COVER);
    }

    ib_fx_circle(&fx, CX, CY, s_core_r + 6, red, LV_OPA_20);
    ib_fx_circle(&fx, CX, CY, s_core_r, red, LV_OPA_COVER);
    if (s_translate) ib_fx_ring(&fx, CX, CY, s_core_r + 6, 3, ib_gray(0xC8), LV_OPA_COVER);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, 0, IB_UI_CONTENT_W, 240, fx_draw, NULL);
    s_hint = ib_label_create(root, &lv_font_montserrat_14, IB_COLOR_TEXT_DIM, 250, IB_UI_CONTENT_W);
    s_mode_caption = lv_label_create(root);
    lv_obj_set_style_text_font(s_mode_caption, &lv_font_montserrat_12, 0);
    lv_obj_set_style_text_color(s_mode_caption, IB_C(IB_COLOR_TEXT_DIM), 0);
    lv_obj_set_pos(s_mode_caption, 10, 2);
    lv_label_set_text_static(s_mode_caption, "TRANSLATE");
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    s_translate = ctx->mode == IB_UI_MODE_TR;
    if (s_translate) lv_obj_remove_flag(s_mode_caption, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_mode_caption, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text_static(s_hint, ctx->ok_held ? "RELEASE OK" : "OK TO STOP");
    lv_obj_invalidate(s_fx);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    for (int i = 0; i < BARS; i++) s_bar_len[i] = BAR_MIN * 16;
    s_glow = 0;
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    uint32_t t = ctx->now_ms - ctx->enter_ms;
    int32_t lvl = ctx->level_smooth;                // 0..1000
    s_glow = ib_ease_out_cubic(ib_progress(ctx->now_ms, ctx->enter_ms, GLOW_IN_MS));

    // 波纹:第 k 圈在 t = k*900 + n*2700 时发射。
    for (int i = 0; i < RIPPLES; i++) {
        if (t < (uint32_t)i * RIPPLE_EVERY_MS) {
            s_ripple_opa[i] = 0;                    // 尚未发射
            continue;
        }
        uint32_t age = (t - (uint32_t)i * RIPPLE_EVERY_MS) % RIPPLE_LIFE_MS;
        int32_t p = (int32_t)(age * IB_P_ONE / RIPPLE_LIFE_MS);
        int32_t reach = 34 + lvl * 16 / 1000;       // 电平越大扩散越远(最远 r=80)
        s_ripple_r[i] = CORE_R + 2 + ib_ease_out_cubic(p) * reach / IB_P_ONE;
        int32_t fade = IB_P_ONE - p;
        s_ripple_opa[i] = ib_opa_scale(150, (int32_t)((int64_t)fade * fade / IB_P_ONE));
    }

    // 电平条:目标 = 电平 x (0.55..1.0 随机) + 缓慢流动的底噪;每帧靠近 35%。
    for (int i = 0; i < BARS; i++) {
        int32_t jitter = 55 + (int32_t)lv_rand(0, 45);                  // %
        int32_t idle = (ib_sin10((int32_t)(t / 3) + i * 450) + 32768) * 4 / 65536;   // 0..4 px
        int32_t target = (BAR_MIN + idle + lvl * BAR_MAX / 1000 * jitter / 100) * 16;
        if (target > BAR_MAX * 16) target = BAR_MAX * 16;
        s_bar_len[i] += (target - s_bar_len[i]) * 35 / 100;
    }
    s_core_r = CORE_R + lvl * 4 / 1000;
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_rec = { create, enter, update, frame };
