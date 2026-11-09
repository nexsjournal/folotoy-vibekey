// main/ib_ui_usage.c: Agent 用量首页(docs/device-ui.md「USAGE」)。
//
// 进入 Agent 应用时先显示这一页,再按 OK 进入原来的 READY 页。布局按 240×320 压缩:
//   标题 > CODEX            应用名
//   TODAY  WEEK  ALL        当前 Tab
//   TODAY TOKENS
//   43,051,522              选中周期的 Token 数(24 px)
//   ┌────────────────────┐
//   │ WEEK LEFT      7%  │
//   │ ███████████░░░░░░  │
//   │ RESET 4D 2H        │
//   │ PLAN PLUS  CREDITS │
//   └────────────────────┘
//   TAP OK: READY  HOLD: TALK
//
// 设备只显示;Tab、数值和额度都由 Mac 的 usage 命令决定。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#include <stdio.h>
#include <string.h>

#define PANEL_X     6
#define PANEL_Y     118
#define PANEL_W     206
#define PANEL_H     148
#define INNER_X     (PANEL_X + 8)
#define INNER_W     (PANEL_W - 16)
#define TAB_W       60
#define TAB_X0      12
#define TAB_PITCH   66
#define BAR_Y       (PANEL_Y + 36)
#define RESET_Y     (PANEL_Y + 50)
#define PLAN_Y      (PANEL_Y + 76)
#define CREDIT_Y    (PANEL_Y + 102)
#define FOOTER_Y    276

static lv_obj_t *s_fx;
static lv_obj_t *s_header;
static lv_obj_t *s_tabs[3];
static lv_obj_t *s_caption;
static lv_obj_t *s_total;
static lv_obj_t *s_detail;
static lv_obj_t *s_week;
static lv_obj_t *s_pct;
static lv_obj_t *s_reset;
static lv_obj_t *s_plan;
static lv_obj_t *s_credit;
static lv_obj_t *s_footer;

static ib_ui_usage_t s_view;
static char s_header_text[IB_UI_USAGE_TEXT_MAX];
static char s_pct_text[12];
static char s_reset_text[32];
static char s_plan_text[32];
static char s_credit_text[20];
static const char *const TAB_NAMES[3] = { "TODAY", "WEEK", "ALL" };
static const char *const CAPTION_NAMES[3] = { "TODAY TOKENS", "WEEK TOKENS", "TOTAL TOKENS" };

static const char *selected_tokens(void)
{
    switch (s_view.tab) {
    case 1: return s_view.week;
    case 2: return s_view.total;
    default: return s_view.today;
    }
}

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    lv_color_t soft = IB_C(IB_COLOR_MATRIX_SOFT);
    lv_color_t frame = IB_C(IB_COLOR_MATRIX_FRAME);

    // 和 READY 页的点阵框一致:不填底色,只留一圈细绿色描边。
    ib_fx_frame(&fx, PANEL_X, PANEL_Y, PANEL_W, PANEL_H, 0, 1, frame, LV_OPA_COVER);

    // 当前 Tab 下方一条短亮线。
    int tab = s_view.tab > 2 ? 0 : s_view.tab;
    ib_fx_rect(&fx, TAB_X0 + tab * TAB_PITCH, 49, 44, 2, 1, soft, LV_OPA_COVER);

    // 周额度进度:只有 Mac 明确给出额度时才画填充。
    if (s_view.has_quota) {
        int32_t left = s_view.left_percent > 100 ? 100 : s_view.left_percent;
        ib_fx_rect(&fx, INNER_X, BAR_Y, INNER_W, 5, 2, frame, LV_OPA_COVER);
        int32_t fill = INNER_W * left / 100;
        if (fill > 0) ib_fx_rect(&fx, INNER_X, BAR_Y, fill, 5, 2, soft, LV_OPA_COVER);
    }
}

static lv_obj_t *label(lv_obj_t *parent, const lv_font_t *font, uint32_t color,
                       int32_t x, int32_t y, int32_t w, int32_t h)
{
    lv_obj_t *l = ib_label_create(parent, font, color, y, w);
    lv_obj_set_height(l, h);
    lv_obj_align(l, LV_ALIGN_TOP_LEFT, x, y);
    lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_CLIP);
    return l;
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H, fx_draw, NULL);

    s_header = label(root, &ib_terminal_font_20, IB_COLOR_MATRIX_SOFT, TAB_X0, 5, 198, 25);
    lv_obj_set_style_text_align(s_header, LV_TEXT_ALIGN_LEFT, 0);
    for (int i = 0; i < 3; i++) {
        s_tabs[i] = label(root, &ib_terminal_font_12, IB_COLOR_TEXT_DIM,
                          TAB_X0 + i * TAB_PITCH, 33, TAB_W, 15);
        lv_obj_set_style_text_align(s_tabs[i], LV_TEXT_ALIGN_LEFT, 0);
    }
    s_caption = label(root, &ib_terminal_font_12, IB_COLOR_TEXT_DIM, TAB_X0, 56, 198, 15);
    lv_obj_set_style_text_align(s_caption, LV_TEXT_ALIGN_LEFT, 0);
    s_total = label(root, &ib_terminal_font_24, IB_COLOR_TEXT, TAB_X0, 70, 198, 34);
    lv_obj_set_style_text_align(s_total, LV_TEXT_ALIGN_LEFT, 0);
    s_detail = label(root, &ib_terminal_font_12, IB_COLOR_TEXT_DIM, TAB_X0, 104, 198, 15);
    lv_obj_set_style_text_align(s_detail, LV_TEXT_ALIGN_LEFT, 0);

    s_week = label(root, &ib_terminal_font_14, IB_COLOR_TEXT_DIM, INNER_X, PANEL_Y + 12, 90, 18);
    s_pct = label(root, &ib_terminal_font_14, IB_COLOR_MATRIX_SOFT, INNER_X + 92, PANEL_Y + 12, INNER_W - 92, 18);
    lv_obj_set_style_text_align(s_week, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_set_style_text_align(s_pct, LV_TEXT_ALIGN_LEFT, 0);
    s_reset = label(root, &ib_terminal_font_14, IB_COLOR_TEXT_DIM, INNER_X, RESET_Y, INNER_W, 18);
    s_plan = label(root, &ib_terminal_font_14, IB_COLOR_TEXT_DIM, INNER_X, PLAN_Y, INNER_W, 18);
    s_credit = label(root, &ib_terminal_font_14, IB_COLOR_TEXT_DIM, INNER_X, CREDIT_Y, INNER_W, 18);
    lv_obj_set_style_text_align(s_reset, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_set_style_text_align(s_plan, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_set_style_text_align(s_credit, LV_TEXT_ALIGN_LEFT, 0);
    s_footer = label(root, &ib_terminal_font_12, IB_COLOR_TEXT_DIM, TAB_X0, FOOTER_Y, IB_UI_CONTENT_W - TAB_X0, 15);
    lv_obj_set_style_text_align(s_footer, LV_TEXT_ALIGN_LEFT, 0);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    s_view = ctx->usage;
    if (s_view.tab > 2) s_view.tab = 0;
    if (!s_view.app[0]) strcpy(s_view.app, "AGENT");

    snprintf(s_header_text, sizeof(s_header_text), "> %s", s_view.app);
    lv_label_set_text_static(s_header, s_header_text);
    for (int i = 0; i < 3; i++) {
        lv_label_set_text_static(s_tabs[i], TAB_NAMES[i]);
        lv_obj_set_style_text_color(s_tabs[i], lv_color_hex(i == s_view.tab ? IB_COLOR_MATRIX_BRIGHT : IB_COLOR_TEXT_DIM), 0);
    }
    lv_label_set_text_static(s_caption, CAPTION_NAMES[s_view.tab]);

    const char *tokens = selected_tokens();
    lv_label_set_text_static(s_total, !s_view.ready ? "..." : (tokens[0] ? tokens : "--"));
    lv_label_set_text_static(s_detail, !s_view.ready ? "READING USAGE..." :
                             (tokens[0] ? "TOKENS" : "NO USAGE DATA"));

    if (s_view.has_quota && s_view.ready) {
        snprintf(s_pct_text, sizeof(s_pct_text), "%u%%", (unsigned)s_view.left_percent);
    } else {
        snprintf(s_pct_text, sizeof(s_pct_text), "%s", s_view.ready ? "NO DATA" : "...");
    }
    lv_label_set_text_static(s_week, "WEEK LEFT");
    lv_label_set_text_static(s_pct, s_pct_text);
    lv_obj_set_style_text_color(s_pct, lv_color_hex(s_view.has_quota && s_view.ready
                                                        ? IB_COLOR_MATRIX_SOFT : IB_COLOR_TEXT_DIM), 0);

    if (s_view.ready && s_view.reset[0]) {
        snprintf(s_reset_text, sizeof(s_reset_text), "RESET %s", s_view.reset);
    } else {
        snprintf(s_reset_text, sizeof(s_reset_text), "RESET --");
    }
    lv_label_set_text_static(s_reset, s_reset_text);
    snprintf(s_plan_text, sizeof(s_plan_text), "PLAN %s", s_view.ready && s_view.plan[0] ? s_view.plan : "--");
    lv_label_set_text_static(s_plan, s_plan_text);
    if (s_view.ready && s_view.credits >= 0) {
        snprintf(s_credit_text, sizeof(s_credit_text), "CREDITS %u", (unsigned)s_view.credits);
    } else {
        snprintf(s_credit_text, sizeof(s_credit_text), "CREDITS --");
    }
    lv_label_set_text_static(s_credit, s_credit_text);

    lv_label_set_text_static(s_footer, s_view.ready ? "TAP OK: READY  HOLD: TALK" : "READING USAGE...");
    lv_obj_invalidate(s_fx);
}

static void enter(const ib_ui_ctx_t *ctx) { update(ctx); }
static void frame(const ib_ui_ctx_t *ctx) { (void)ctx; }

const ib_ui_page_t ib_ui_page_usage = { create, enter, update, frame };
