// main/ib_ui_gfx.c: UI 绘图工具实现(见 ib_ui_gfx.h)。
#include "ib_ui_gfx.h"

int32_t ib_ease_out_cubic(int32_t p)
{
    if (p <= 0) return 0;
    if (p >= IB_P_ONE) return IB_P_ONE;
    int64_t q = IB_P_ONE - p;
    return IB_P_ONE - (int32_t)(q * q * q / ((int64_t)IB_P_ONE * IB_P_ONE));
}

int32_t ib_ease_in_out_sine(int32_t p)
{
    if (p <= 0) return 0;
    if (p >= IB_P_ONE) return IB_P_ONE;
    // (1 - cos(pi * p)) / 2
    int32_t c = ib_cos10(p * 1800 / IB_P_ONE);
    return (int32_t)(((int64_t)(32768 - c) * IB_P_ONE) / 65536);
}

int32_t ib_progress(uint32_t t, uint32_t t0, uint32_t dur)
{
    if (t <= t0) return 0;
    uint32_t d = t - t0;
    if (dur == 0 || d >= dur) return IB_P_ONE;
    return (int32_t)((uint64_t)d * IB_P_ONE / dur);
}

int32_t ib_breath(uint32_t now_ms, uint32_t period_ms)
{
    // 0 → 1 → 0 的余弦波,起点为 0。
    int32_t phase = (int32_t)((uint64_t)(now_ms % period_ms) * 3600 / period_ms);
    return (int32_t)(((int64_t)(32768 - ib_cos10(phase)) * IB_P_ONE) / 65536);
}

int32_t ib_sin10(int32_t deci_deg)
{
    // lv_trigo_sin 以整度为单位;在相邻两度之间线性插值,得到 0.1 度精度。
    deci_deg %= 3600;
    if (deci_deg < 0) deci_deg += 3600;
    int32_t d = deci_deg / 10;
    int32_t f = deci_deg % 10;
    int32_t a = lv_trigo_sin((int16_t)d);
    int32_t b = lv_trigo_sin((int16_t)(d + 1));
    return a + (b - a) * f / 10;
}

int32_t ib_cos10(int32_t deci_deg)
{
    return ib_sin10(deci_deg + 900);
}

int32_t ib_lerp(int32_t a, int32_t b, int32_t p)
{
    return a + (int32_t)(((int64_t)(b - a) * p) / IB_P_ONE);
}

lv_opa_t ib_opa_scale(int32_t opa, int32_t p)
{
    int32_t v = (int32_t)(((int64_t)opa * p) / IB_P_ONE);
    if (v < 0) v = 0;
    if (v > 255) v = 255;
    return (lv_opa_t)v;
}

lv_obj_t *ib_box_create(lv_obj_t *parent, int32_t x, int32_t y, int32_t w, int32_t h)
{
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(o, x, y);
    lv_obj_set_size(o, w, h);
    return o;
}

lv_obj_t *ib_fx_create(lv_obj_t *parent, int32_t x, int32_t y, int32_t w, int32_t h, lv_event_cb_t draw_cb, void *user)
{
    lv_obj_t *o = ib_box_create(parent, x, y, w, h);
    lv_obj_add_event_cb(o, draw_cb, LV_EVENT_DRAW_MAIN, user);
    return o;
}

lv_obj_t *ib_label_create(lv_obj_t *parent, const lv_font_t *font, uint32_t color, int32_t y, int32_t w)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_width(l, w);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_CLIP);
    lv_obj_align(l, LV_ALIGN_TOP_MID, 0, y);
    lv_label_set_text_static(l, "");
    return l;
}

void ib_fx_begin(ib_fx_t *fx, lv_event_t *e)
{
    lv_obj_t *obj = lv_event_get_target_obj(e);
    lv_area_t a;
    lv_obj_get_coords(obj, &a);
    fx->layer = lv_event_get_layer(e);
    fx->ox = a.x1;
    fx->oy = a.y1;
    fx->w = lv_area_get_width(&a);
    fx->h = lv_area_get_height(&a);
    fx->opa = lv_obj_get_style_opa_recursive(obj, LV_PART_MAIN);
}

static lv_opa_t mix_opa(const ib_fx_t *fx, lv_opa_t opa)
{
    return (lv_opa_t)(((uint32_t)opa * fx->opa) / 255U);
}

void ib_fx_circle(const ib_fx_t *fx, int32_t cx, int32_t cy, int32_t r, lv_color_t c, lv_opa_t opa)
{
    if (r <= 0 || (opa = mix_opa(fx, opa)) < LV_OPA_MIN) return;
    lv_draw_rect_dsc_t d;
    lv_draw_rect_dsc_init(&d);
    d.radius = LV_RADIUS_CIRCLE;
    d.bg_color = c;
    d.bg_opa = opa;
    lv_area_t a = { fx->ox + cx - r, fx->oy + cy - r, fx->ox + cx + r - 1, fx->oy + cy + r - 1 };
    lv_draw_rect(fx->layer, &d, &a);
}

void ib_fx_arc(const ib_fx_t *fx, int32_t cx, int32_t cy, int32_t r, int32_t width, int32_t start, int32_t end,
               lv_color_t c, lv_opa_t opa)
{
    if (r <= 0 || width <= 0 || start == end || (opa = mix_opa(fx, opa)) < LV_OPA_MIN) return;
    lv_draw_arc_dsc_t d;
    lv_draw_arc_dsc_init(&d);
    d.color = c;
    d.opa = opa;
    d.width = width > r ? r : width;
    d.radius = (uint16_t)r;
    d.center.x = fx->ox + cx;
    d.center.y = fx->oy + cy;
    d.start_angle = start;
    d.end_angle = end;
    d.rounded = (end - start) < 360;
    lv_draw_arc(fx->layer, &d);
}

void ib_fx_ring(const ib_fx_t *fx, int32_t cx, int32_t cy, int32_t r, int32_t width, lv_color_t c, lv_opa_t opa)
{
    ib_fx_arc(fx, cx, cy, r, width, 0, 360, c, opa);
}

void ib_fx_line(const ib_fx_t *fx, int32_t x1, int32_t y1, int32_t x2, int32_t y2, int32_t width, lv_color_t c,
                lv_opa_t opa)
{
    if (width <= 0 || (opa = mix_opa(fx, opa)) < LV_OPA_MIN) return;
    lv_draw_line_dsc_t d;
    lv_draw_line_dsc_init(&d);
    d.color = c;
    d.opa = opa;
    d.width = width;
    d.round_start = 1;
    d.round_end = 1;
    d.p1.x = fx->ox + x1;
    d.p1.y = fx->oy + y1;
    d.p2.x = fx->ox + x2;
    d.p2.y = fx->oy + y2;
    lv_draw_line(fx->layer, &d);
}

void ib_fx_rect(const ib_fx_t *fx, int32_t x, int32_t y, int32_t w, int32_t h, int32_t radius, lv_color_t c,
                lv_opa_t opa)
{
    if (w <= 0 || h <= 0 || (opa = mix_opa(fx, opa)) < LV_OPA_MIN) return;
    lv_draw_rect_dsc_t d;
    lv_draw_rect_dsc_init(&d);
    d.radius = radius;
    d.bg_color = c;
    d.bg_opa = opa;
    lv_area_t a = { fx->ox + x, fx->oy + y, fx->ox + x + w - 1, fx->oy + y + h - 1 };
    lv_draw_rect(fx->layer, &d, &a);
}

void ib_fx_rect_vgrad(const ib_fx_t *fx, int32_t x, int32_t y, int32_t w, int32_t h, int32_t radius,
                      lv_color_t top, lv_color_t bottom, lv_opa_t opa)
{
    if (w <= 0 || h <= 0 || (opa = mix_opa(fx, opa)) < LV_OPA_MIN) return;
    lv_draw_rect_dsc_t d;
    lv_draw_rect_dsc_init(&d);
    d.radius = radius;
    d.bg_opa = opa;
    d.bg_color = top;
    d.bg_grad.dir = LV_GRAD_DIR_VER;
    d.bg_grad.stops_count = 2;
    d.bg_grad.stops[0].color = top;
    d.bg_grad.stops[0].opa = LV_OPA_COVER;
    d.bg_grad.stops[0].frac = 0;
    d.bg_grad.stops[1].color = bottom;
    d.bg_grad.stops[1].opa = LV_OPA_COVER;
    d.bg_grad.stops[1].frac = 255;
    lv_area_t a = { fx->ox + x, fx->oy + y, fx->ox + x + w - 1, fx->oy + y + h - 1 };
    lv_draw_rect(fx->layer, &d, &a);
}

void ib_fx_frame(const ib_fx_t *fx, int32_t x, int32_t y, int32_t w, int32_t h, int32_t radius, int32_t border,
                 lv_color_t c, lv_opa_t opa)
{
    if (w <= 0 || h <= 0 || border <= 0 || (opa = mix_opa(fx, opa)) < LV_OPA_MIN) return;
    lv_draw_rect_dsc_t d;
    lv_draw_rect_dsc_init(&d);
    d.radius = radius;
    d.bg_opa = LV_OPA_TRANSP;
    d.border_color = c;
    d.border_opa = opa;
    d.border_width = border;
    lv_area_t a = { fx->ox + x, fx->oy + y, fx->ox + x + w - 1, fx->oy + y + h - 1 };
    lv_draw_rect(fx->layer, &d, &a);
}

void ib_fx_text(const ib_fx_t *fx, int32_t cx, int32_t cy, const char *text, const lv_font_t *font, lv_color_t c,
                lv_opa_t opa)
{
    if ((opa = mix_opa(fx, opa)) < LV_OPA_MIN) return;
    lv_draw_label_dsc_t d;
    lv_draw_label_dsc_init(&d);
    d.text = text;
    d.font = font;
    d.color = c;
    d.opa = opa;
    d.align = LV_TEXT_ALIGN_CENTER;
    int32_t h = lv_font_get_line_height(font);
    lv_area_t a = { fx->ox + cx - 60, fx->oy + cy - h / 2, fx->ox + cx + 60, fx->oy + cy + h / 2 };
    lv_draw_label(fx->layer, &d, &a);
}

void ib_fx_text_left(const ib_fx_t *fx, int32_t x, int32_t cy, const char *text, const lv_font_t *font,
                     lv_color_t c, lv_opa_t opa)
{
    if ((opa = mix_opa(fx, opa)) < LV_OPA_MIN) return;
    lv_draw_label_dsc_t d;
    lv_draw_label_dsc_init(&d);
    d.text = text;
    d.font = font;
    d.color = c;
    d.opa = opa;
    d.align = LV_TEXT_ALIGN_LEFT;
    d.flag = LV_TEXT_FLAG_EXPAND;       // 单行,不折行
    int32_t h = lv_font_get_line_height(font);
    lv_area_t a = { fx->ox + x, fx->oy + cy - h / 2, fx->ox + fx->w - 1, fx->oy + cy + h / 2 };
    lv_draw_label(fx->layer, &d, &a);
}

void ib_text_fit(const char *text, const lv_font_t *font, int32_t max_w, char *out, size_t cap)
{
    if (cap == 0) return;
    int32_t dots = 2 * lv_font_get_glyph_width(font, '.', '.');
    int32_t w = 0;
    size_t n = 0;
    size_t keep = 0;                    // 加 ".." 时能保留的字符数
    for (; text && text[n] && n + 1 < cap; n++) {
        w += lv_font_get_glyph_width(font, (uint8_t)text[n], (uint8_t)text[n + 1]);
        if (w + dots <= max_w) keep = n + 1;
        if (w > max_w) break;
        out[n] = text[n];
    }
    if (text && text[n] && w > max_w) {
        // 放不下:截到 keep 个字符再加 ".."。
        if (keep + 3 > cap) keep = cap - 3;
        out[keep] = '.';
        out[keep + 1] = '.';
        out[keep + 2] = '\0';
        return;
    }
    out[n] = '\0';
}

lv_color_t ib_gray(int32_t v)
{
    if (v < 0) v = 0;
    if (v > 255) v = 255;
    uint8_t g = (uint8_t)(v & 0xF8);
    return lv_color_make(g, g, g);
}

lv_color_t ib_gray_lerp(uint32_t from_hex, uint32_t to_hex, int32_t p)
{
    return ib_gray(ib_lerp((int32_t)(from_hex & 0xFF), (int32_t)(to_hex & 0xFF), p));
}

static const char *const LARGE_GLYPHS[IB_GLYPH_COUNT] = {
#define IB_ICON_LARGE_DEF(name, glyph, codepoint) [IB_GLYPH_##name] = glyph,
#include "icons/ib_icon_large_list.h"
#undef IB_ICON_LARGE_DEF
};

const char *ib_glyph(ib_glyph_t glyph)
{
    return (unsigned)glyph < IB_GLYPH_COUNT ? LARGE_GLYPHS[glyph] : "";
}
