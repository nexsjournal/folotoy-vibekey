// main/ib_ui_hints.c: 右侧按键提示列实现(见 ib_ui_hints.h)。
#include "ib_ui_hints.h"

#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define PRESS_MS    150
#define ICON_SIZE   24          // 图标标签的宽高(字形 22 px)
#define ARROW_W     8           // ">" 控件宽度
#define ARROW_H     14
#define EDGE_PAD    2           // 箭头离屏幕右边缘的距离
#define ICON_GAP    1

// 图标 → UTF-8 字形,与字体同源(icons/ib_icon_list.h 由 tools/gen-icon-font.sh 生成)。
static const char *const GLYPHS[IB_ICON_COUNT] = {
    [IB_ICON_NONE] = "",
#define IB_ICON_DEF(name, id, glyph, codepoint) [IB_ICON_##name] = glyph,
#include "icons/ib_icon_list.h"
#undef IB_ICON_DEF
};

typedef struct {
    lv_obj_t *icon;
    lv_obj_t *arrow;
    int32_t flash;              // 0..255:按下闪白的强度
} hint_t;

static lv_obj_t *s_layer;
static hint_t s_hints[IB_UI_KEY_COUNT];

static lv_color_t hint_color(const hint_t *h)
{
    return ib_gray_lerp(IB_COLOR_TEXT_DIM, IB_COLOR_TEXT, h->flash * IB_P_ONE / 255);
}

static void arrow_draw(lv_event_t *e)
{
    const hint_t *h = lv_event_get_user_data(e);
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    // 指向右侧机身边缘的 ">"。
    int32_t x0 = 1, x1 = fx.w - 2, cy = fx.h / 2;
    lv_color_t c = hint_color(h);
    ib_fx_line(&fx, x0, cy - 4, x1, cy, 2, c, LV_OPA_COVER);
    ib_fx_line(&fx, x1, cy, x0, cy + 4, 2, c, LV_OPA_COVER);
}

static void flash_cb(void *var, int32_t v)
{
    hint_t *h = var;
    h->flash = v;
    lv_obj_set_style_text_color(h->icon, hint_color(h), 0);
    lv_obj_invalidate(h->arrow);
}

void ib_hints_create(lv_obj_t *screen)
{
    static const int32_t YS[IB_UI_KEY_COUNT] = {
        [IB_UI_KEY_UP] = IB_HINT_Y_UP, [IB_UI_KEY_DOWN] = IB_HINT_Y_DOWN, [IB_UI_KEY_OK] = IB_HINT_Y_OK,
    };
    const int32_t arrow_x = IB_HINT_COL_W - EDGE_PAD - ARROW_W;
    const int32_t icon_x = arrow_x - ICON_GAP - ICON_SIZE;
    s_layer = ib_box_create(screen, IB_UI_W - IB_HINT_COL_W, 0, IB_HINT_COL_W, IB_UI_H);
    for (int k = 0; k < IB_UI_KEY_COUNT; k++) {
        hint_t *h = &s_hints[k];
        h->icon = lv_label_create(s_layer);
        lv_obj_set_style_text_font(h->icon, &ib_icon_font_22, 0);
        lv_obj_set_style_text_color(h->icon, IB_C(IB_COLOR_TEXT_DIM), 0);
        lv_obj_set_style_text_align(h->icon, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_set_size(h->icon, ICON_SIZE, ICON_SIZE);
        // 字体行高 20 px:在 24 px 高的标签里上下各留 2 px,图标中心落在 YS[k]。
        lv_obj_set_style_pad_top(h->icon, (ICON_SIZE - lv_font_get_line_height(&ib_icon_font_22)) / 2, 0);
        lv_obj_set_pos(h->icon, icon_x, YS[k] - ICON_SIZE / 2);
        lv_label_set_text_static(h->icon, GLYPHS[IB_ICON_NONE]);
        h->arrow = ib_fx_create(s_layer, arrow_x, YS[k] - ARROW_H / 2, ARROW_W, ARROW_H, arrow_draw, h);
        lv_obj_add_flag(h->icon, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(h->arrow, LV_OBJ_FLAG_HIDDEN);
    }
}

void ib_hints_set_icon(ib_ui_key_t key, ib_icon_t icon)
{
    if ((unsigned)key >= IB_UI_KEY_COUNT) return;
    hint_t *h = &s_hints[key];
    if ((unsigned)icon >= IB_ICON_COUNT) icon = IB_ICON_NONE;
    lv_label_set_text_static(h->icon, GLYPHS[icon]);
    if (icon == IB_ICON_NONE) {
        lv_obj_add_flag(h->icon, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(h->arrow, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_remove_flag(h->icon, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(h->arrow, LV_OBJ_FLAG_HIDDEN);
    }
}

void ib_hints_press(ib_ui_key_t key)
{
    if ((unsigned)key >= IB_UI_KEY_COUNT) return;
    hint_t *h = &s_hints[key];
    lv_anim_delete(h, flash_cb);
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, h);
    lv_anim_set_exec_cb(&a, flash_cb);
    lv_anim_set_values(&a, 255, 0);
    lv_anim_set_duration(&a, PRESS_MS);
    lv_anim_set_path_cb(&a, lv_anim_path_ease_in);
    lv_anim_start(&a);
}

void ib_hints_set_visible(bool visible)
{
    if (visible) lv_obj_remove_flag(s_layer, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_layer, LV_OBJ_FLAG_HIDDEN);
}
