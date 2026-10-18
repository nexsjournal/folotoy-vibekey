// main/ib_ui_dots.c: 点阵实现(见 ib_ui_dots.h)。
#include "ib_ui_dots.h"

#include "ib_ui_wave.h"

#include <string.h>

#define FLY_MS          240     // 单颗点的飞行时长
#define STAGGER_MS      6       // 每列的起飞延迟(从左到右"重新像素化")
#define COLLAPSE_MS     120     // 声波按行塌缩成线

// ---- 字形(X = 点;原点为左上角所在的网格 (列, 行))----
typedef struct {
    int8_t c0, r0;
    uint8_t w, h;
    const char *rows[10];
} glyph_t;

static const glyph_t GLYPHS[IB_DOTS_GLYPH_COUNT] = {
    [IB_DOTS_MIC] = { 8, 8, 9, 10, {
        "...XXX...", "..XXXXX..", "..XXXXX..", "X.XXXXX.X", "X.XXXXX.X",
        "X..XXX..X", ".X.....X.", "..XXXXX..", "....X....", "..XXXXX..",
    } },
    [IB_DOTS_TR] = { 8, 8, 9, 10, {
        "XXXXXX...", "X....X...", "X.XX.X...", "X...XXXXX", "XXXX....X",
        ".X.X.XX.X", "...X....X", "...XXXXXX", ".......X.", "......X..",
    } },
    [IB_DOTS_CC] = { 8, 10, 9, 7, {
        "XXXXXXXXX", "X.......X", "X.XX.XX.X", "X.X..X..X", "X.XX.XX.X", "X.......X", "XXXXXXXXX",
    } },
    [IB_DOTS_CHECK] = { 7, 9, 11, 8, {
        "..........X", ".........XX", "........XX.", ".......XX..", "X.....XX...",
        "XX...XX....", ".XXXXX.....", "..XXX......",
    } },
    [IB_DOTS_X] = { 8, 9, 9, 9, {
        "X.......X", "XX.....XX", ".XX...XX.", "..XX.XX..", "...XXX...",
        "..XX.XX..", ".XX...XX.", "XX.....XX", "X.......X",
    } },
    [IB_DOTS_BANG] = { 11, 8, 3, 10, {
        "XXX", "XXX", "XXX", "XXX", "XXX", "XXX", ".X.", "...", "XXX", "XXX",
    } },
};

// ---- 转场状态(全局唯一,各页共用)----
static ib_dots_t s_from;            // 重排的起点
static ib_dots_t s_to;              // 目标(当前图案)
static uint32_t s_start;            // 重排开始时刻(塌缩之后)
static uint32_t s_collapse_start;   // 声波塌缩开始时刻
static bool s_collapsing;
static bool s_morph;

int32_t ib_dots_x(int32_t c)
{
    return IB_UI_CX - (IB_DOTS_COLS / 2) * IB_DOTS_PITCH + c * IB_DOTS_PITCH;
}

int32_t ib_dots_y(int32_t r)
{
    return 28 + r * IB_DOTS_PITCH - (IB_DOTS_BOX_Y + IB_UI_BAR_H);
}

lv_color_t ib_dots_color(uint8_t color)
{
    switch (color) {
    case IB_DOT_SOFT: return ib_gray(0xC8);
    case IB_DOT_GRAY: return IB_C(IB_COLOR_RING);
    case IB_DOT_DIM: return IB_C(IB_COLOR_MUTE);
    case IB_DOT_REC: return IB_C(IB_COLOR_REC);
    case IB_DOT_DONE: return IB_C(IB_COLOR_DONE);
    case IB_DOT_ERR: return IB_C(IB_COLOR_ERR);
    default: return IB_C(IB_COLOR_TEXT);
    }
}

void ib_dots_dot(const ib_fx_t *fx, int32_t x, int32_t y, lv_color_t c, int32_t grow)
{
    int32_t s = 5 + 2 * grow;
    ib_fx_rect(fx, x - s / 2, y - s / 2, s, s, s / 2, c, LV_OPA_COVER);
}

void ib_dots_glyph(ib_dots_t *out, ib_dots_glyph_t glyph, uint8_t color)
{
    out->n = 0;
    if ((unsigned)glyph >= IB_DOTS_GLYPH_COUNT) return;
    const glyph_t *g = &GLYPHS[glyph];
    // 按列优先排序(从左到右),重排时与另一个图案按序号配对。
    for (int c = 0; c < g->w; c++) {
        for (int r = 0; r < g->h; r++) {
            if (g->rows[r][c] == 'X' && out->n < IB_DOTS_MAX) {
                out->d[out->n++] = (ib_dot_t){ (int8_t)(g->c0 + c), (int8_t)(g->r0 + r), color };
            }
        }
    }
}

void ib_dots_line(ib_dots_t *out, uint8_t color, uint8_t center)
{
    out->n = 0;
    for (int c = 0; c < IB_DOTS_COLS; c++) {
        out->d[out->n++] = (ib_dot_t){ (int8_t)c, IB_DOTS_ROW_MID, c == IB_DOTS_COLS / 2 ? center : color };
    }
}

static uint32_t morph_ms(void)
{
    return (uint32_t)(STAGGER_MS * (IB_DOTS_COLS - 1) + FLY_MS);
}

void ib_dots_show(const ib_dots_t *target, bool animate, bool from_wave, uint32_t now_ms)
{
    if (animate) {
        if (from_wave) {
            // 声波塌缩成的那条线就是重排的起点(颜色取塌缩前的活柱 / 历史柱颜色)。
            ib_dots_line(&s_from, IB_DOT_WHITE, ib_wave_shared()->live_color);
        } else {
            s_from = s_to;
        }
        s_collapsing = from_wave;
        s_collapse_start = now_ms;
        s_start = now_ms + (from_wave ? COLLAPSE_MS : 0);
        s_morph = s_from.n > 0;
    } else {
        s_collapsing = false;
        s_morph = false;
        s_start = now_ms;
    }
    s_to = *target;
}

void ib_dots_enter(const ib_ui_ctx_t *ctx, const ib_dots_t *target)
{
    bool cut = ctx->prev_screen != IB_UI_SCREEN_NONE;
    bool from_wave = ctx->prev_screen == IB_UI_REC || ctx->prev_screen == IB_UI_SUB;
    ib_dots_show(target, cut, cut && from_wave, ctx->enter_ms);
}

uint32_t ib_dots_settle_ms(void)
{
    return s_morph ? s_start + morph_ms() : s_start;
}

bool ib_dots_settled(uint32_t now_ms)
{
    return (int32_t)(now_ms - ib_dots_settle_ms()) >= 0;
}

const ib_dots_t *ib_dots_current(void)
{
    return &s_to;
}

static void draw_static(const ib_fx_t *fx, int32_t dx)
{
    for (int i = 0; i < s_to.n; i++) {
        const ib_dot_t *d = &s_to.d[i];
        ib_dots_dot(fx, ib_dots_x(d->c) + dx, ib_dots_y(d->r), ib_dots_color(d->color), 0);
    }
}

void ib_dots_draw(const ib_fx_t *fx, uint32_t now_ms, int32_t dx)
{
    if (s_collapsing && (int32_t)(now_ms - s_start) < 0) {
        // 塌缩:声波柱高按 ease-in 收到 0(拍数冻结,不再流动)。
        ib_wave_t *w = ib_wave_shared();
        w->intro = ib_ease_out_cubic(IB_P_ONE - ib_progress(now_ms, s_collapse_start, COLLAPSE_MS));   // 1 - ease_in(p)
        ib_wave_draw(fx, w);
        return;
    }
    if (!s_morph || ib_dots_settled(now_ms)) {
        draw_static(fx, dx);
        return;
    }
    // 重排:两个图案按序号配对,数量不同时循环复用;目标列越靠右起飞越晚。
    int n = s_from.n > s_to.n ? s_from.n : s_to.n;
    uint32_t t = now_ms - s_start;
    for (int i = 0; i < n; i++) {
        const ib_dot_t *a = &s_from.d[i * s_from.n / n];
        const ib_dot_t *b = &s_to.d[i * s_to.n / n];
        int32_t p = ib_ease_in_out_cubic(ib_progress(t, (uint32_t)(STAGGER_MS * b->c), FLY_MS));
        int32_t x = ib_lerp(ib_dots_x(a->c), ib_dots_x(b->c), p) + dx;
        int32_t y = ib_lerp(ib_dots_y(a->r), ib_dots_y(b->r), p);
        lv_color_t c = lv_color_mix(ib_dots_color(b->color), ib_dots_color(a->color), (uint8_t)(p * 255 / IB_P_ONE));
        // 飞行中略微放大(半程最大 +1 px),落地还原。
        int32_t grow = p > 0 && p < IB_P_ONE ? ib_sin10(p * 1800 / IB_P_ONE) / 32768 : 0;
        ib_dots_dot(fx, x, y, c, grow);
    }
}
