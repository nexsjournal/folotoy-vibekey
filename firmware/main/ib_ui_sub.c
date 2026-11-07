// main/ib_ui_sub.c: SUB 页:字幕运行中显示应用名 + 原文 + 译文。
//
// 布局(页面坐标,状态栏下方 296 px):
//   应用名   12 px,左上 y=2,超长省略
//   原文字幕 12 px 中文/英文,wrap,左上 y=22,高 76
//   译文     12 px 中文/英文,wrap,左上 y=106,高 170;未开启翻译时隐藏
// 进入时先播放点阵转场(CC 图标),转场结束后隐藏点阵、显示文字;之后只更新文字。
// 字幕文本走 caption 命令(UTF-8),应用名走同一命令的 app 字段;state.msg 作为旧固件的 ASCII 回退。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define TEXT_X      8
#define TEXT_W      (IB_UI_CONTENT_W - TEXT_X * 2)
#define APP_TOP     2
#define SRC_TOP     22
#define SRC_H       76
#define DST_TOP     106
#define DST_H       170

static lv_obj_t *s_fx;
static lv_obj_t *s_app;
static lv_obj_t *s_src;
static lv_obj_t *s_dst;
static lv_obj_t *s_divider;
static bool s_text_on;

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    ib_dots_draw(&fx, lv_tick_get(), 0);
}

static lv_obj_t *text_label(lv_obj_t *parent, uint32_t color, int32_t top, int32_t height)
{
    lv_obj_t *label = ib_label_create(parent, &ib_cjk_font_12, color, top, TEXT_W);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_set_style_text_line_space(label, 1, 0);
    lv_obj_align(label, LV_ALIGN_TOP_LEFT, TEXT_X, top);
    lv_obj_set_height(label, height);
    lv_label_set_long_mode(label, LV_LABEL_LONG_MODE_WRAP);
    lv_label_set_text_static(label, "");
    return label;
}

static void hide_text(void)
{
    lv_obj_add_flag(s_app, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(s_src, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(s_dst, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(s_divider, LV_OBJ_FLAG_HIDDEN);
}

static void show_text(void)
{
    lv_obj_remove_flag(s_app, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(s_src, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(s_divider, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(s_dst, LV_OBJ_FLAG_HIDDEN);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);

    s_fx = ib_fx_create(root, 0, IB_DOTS_BOX_Y, IB_UI_CONTENT_W, IB_DOTS_BOX_H, fx_draw, NULL);

    s_app = ib_label_create(root, &ib_cjk_font_12, IB_COLOR_TEXT_MID, APP_TOP, TEXT_W);
    lv_obj_set_style_text_align(s_app, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_align(s_app, LV_ALIGN_TOP_LEFT, TEXT_X, APP_TOP);
    lv_label_set_long_mode(s_app, LV_LABEL_LONG_MODE_DOTS);

    s_divider = ib_box_create(root, TEXT_X, SRC_TOP + SRC_H + 2, TEXT_W, 1);
    lv_obj_set_style_bg_color(s_divider, IB_C(IB_COLOR_MATRIX_FRAME), 0);
    lv_obj_set_style_bg_opa(s_divider, LV_OPA_COVER, 0);

    s_src = text_label(root, IB_COLOR_TEXT, SRC_TOP, SRC_H);
    s_dst = text_label(root, IB_COLOR_MATRIX_SOFT, DST_TOP, DST_H);
    hide_text();
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    const char *app = ctx->caption_app[0] ? ctx->caption_app : ctx->msg;
    lv_label_set_text_static(s_app, app);
    lv_label_set_text_static(s_src, ctx->caption_src);
    lv_label_set_text_static(s_dst, ctx->caption_dst);
    lv_obj_set_style_text_opa(s_dst, ctx->caption_live ? LV_OPA_70 : LV_OPA_COVER, 0);
    if (ctx->caption_dst[0] == '\0') lv_obj_add_flag(s_dst, LV_OBJ_FLAG_HIDDEN);
    else if (s_text_on) lv_obj_remove_flag(s_dst, LV_OBJ_FLAG_HIDDEN);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    ib_dots_t glyph;
    ib_dots_glyph(&glyph, IB_DOTS_CC, IB_DOT_WHITE);
    ib_dots_enter(ctx, &glyph);
    s_text_on = false;
    lv_obj_remove_flag(s_fx, LV_OBJ_FLAG_HIDDEN);
    hide_text();
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    if (!s_text_on && ib_dots_settled(ctx->now_ms)) {
        s_text_on = true;
        lv_obj_add_flag(s_fx, LV_OBJ_FLAG_HIDDEN);
        show_text();
        update(ctx);
    }
}

const ib_ui_page_t ib_ui_page_sub = { create, enter, update, frame };
