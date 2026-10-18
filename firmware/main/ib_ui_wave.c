// main/ib_ui_wave.c: 点阵声波实现(见 ib_ui_wave.h)。
#include "ib_ui_wave.h"

#include "ib_ui_dots.h"

#include <string.h>

#define MAX_HALF   7                // 最大半高(颗):行 6..20
#define TICK_MS    33               // 一拍(约 30 fps)
#define BEAT       3                // 每 3 拍存档一根历史柱(约 100 ms 跳一格)

static ib_wave_t s_shared;

ib_wave_t *ib_wave_shared(void)
{
    return &s_shared;
}

void ib_wave_reset(ib_wave_t *w, ib_wave_layout_t layout, uint32_t now_ms)
{
    memset(w, 0, sizeof(*w));
    w->layout = layout;
    w->cols = layout == IB_WAVE_MIRROR ? IB_DOTS_COLS / 2 : IB_DOTS_COLS - 1;
    w->live_color = layout == IB_WAVE_MIRROR ? IB_DOT_REC : IB_DOT_WHITE;
    w->far = layout == IB_WAVE_MIRROR ? 0x48 : 0x30;
    w->t0 = now_ms;
}

// 电平 → 目标半高(x16)。0.75 次方映射:比线性更容易看到小声,又不像平方根那样一说话就铺满。
static int32_t target_half(int32_t level)
{
    if (level < 0) level = 0;
    if (level > 1000) level = 1000;
    int32_t s = lv_sqrt32((uint32_t)level * 1000U);             // x^0.5,0..1000
    int32_t q = lv_sqrt32((uint32_t)s * 1000U);                 // x^0.25
    return MAX_HALF * 16 * (s * q / 1000) / 1000;               // x^0.75
}

void ib_wave_step(ib_wave_t *w, int32_t level, int32_t intro, uint32_t now_ms)
{
    w->intro = intro;
    uint32_t due = (now_ms - w->t0) / TICK_MS;
    uint32_t limit = (uint32_t)w->cols * BEAT + BEAT;      // 落后太多时只补一整轮
    if (due - w->ticks > limit) w->ticks = due - limit;
    int32_t target = target_half(level);
    while (w->ticks < due) {
        w->ticks++;
        w->live += (target - w->live) / 2;
        if (w->ticks % BEAT == 0 && w->cols > 0) {
            memmove(&w->col[1], &w->col[0], (size_t)(w->cols - 1) * sizeof(w->col[0]));
            w->col[0] = (int16_t)w->live;
        }
    }
}

// 一列:中心行一颗 + 上下各 half 颗(半高按 intro 缩放、四舍五入到整颗)。
static void column(const ib_fx_t *fx, const ib_wave_t *w, int32_t c, int32_t half16, lv_color_t color)
{
    int32_t half = (half16 * w->intro / IB_P_ONE + 8) / 16;
    if (half > MAX_HALF) half = MAX_HALF;
    int32_t x = ib_dots_x(c);
    for (int32_t i = -half; i <= half; i++) ib_dots_dot(fx, x, ib_dots_y(IB_DOTS_ROW_MID + i), color, 0);
}

void ib_wave_draw(const ib_fx_t *fx, const ib_wave_t *w)
{
    int32_t n = w->cols > 1 ? w->cols - 1 : 1;
    for (int k = 0; k < w->cols; k++) {
        lv_color_t g = ib_gray(0xF0 - (0xF0 - w->far) * k / n);     // 越远越暗(精确灰)
        if (w->layout == IB_WAVE_MIRROR) {
            column(fx, w, IB_DOTS_COLS / 2 + 1 + k, w->col[k], g);
            column(fx, w, IB_DOTS_COLS / 2 - 1 - k, w->col[k], g);
        } else {
            column(fx, w, IB_DOTS_COLS - 2 - k, w->col[k], g);
        }
    }
    int32_t live_c = w->layout == IB_WAVE_MIRROR ? IB_DOTS_COLS / 2 : IB_DOTS_COLS - 1;
    column(fx, w, live_c, w->live, ib_dots_color(w->live_color));
}
