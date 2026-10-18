// main/ib_ui_list.c: LIST 页:Mac 驱动的列表(例如应用切换器;docs/device-ui.md「LIST」)。
//
// 设备只负责显示:标题、最多 6 行、选中项、左侧滚动条。选中项与滚动位置都由 Mac 的 list 命令决定,
// 按键仍原样上报给 Mac。
// 布局(屏幕坐标,只用左侧内容区):
//   标题    12 px 大写加字距,深灰,左对齐 x=14,中心 y=36
//   行      x 14..193(宽 180)、高 32、行距 38,首行顶部 y=52;未选中不画底(浅灰字),选中为白色胶囊黑字
//   滚动条  x=4 的 3 px 细轨道,总项数超过可见行数时显示滑块(右侧是按键提示列,所以放左边)
// 选中胶囊是"弹性"的:前沿每帧靠近目标 45%、后沿 25%,移动中被拉长、约 200 ms 收回;文字颜色按胶囊覆盖过半切换。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#include <ctype.h>

#define ROW_X       14
#define ROW_W       192
#define ROW_H       32
#define ROW_PITCH   38
#define ROW_Y0      (52 - IB_UI_BAR_H)
#define ROW_PAD     14          // 行内文字左边距
#define FX_Y        (ROW_Y0 - 2)
#define FX_H        (IB_UI_LIST_ROWS * ROW_PITCH + 4)
#define TRACK_X     4
#define TRACK_W     3
#define TEXT_MAX    28
#define TITLE_CY    (36 - IB_UI_BAR_H)
#define ROW_TEXT    0xC0C0C0    // 未选中行文字

static lv_obj_t *s_title;
static lv_obj_t *s_fx;
static char s_rows[IB_UI_LIST_ROWS][TEXT_MAX];  // 截断后的显示文本(绘制回调读取)
static char s_title_text[IB_UI_TEXT_MAX];       // 大写后的标题
static uint8_t s_count;
static uint16_t s_n, s_top;
static int32_t s_target = -1;       // 选中行在可见区内的序号,-1 表示不在可见区
static int32_t s_lead = 0;          // 胶囊前沿 / 后沿的行顶纵坐标(x16,控件坐标)
static int32_t s_trail = 0;

static int32_t row_y(int32_t row)
{
    return 2 + row * ROW_PITCH;     // 控件坐标
}

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    lv_color_t white = IB_C(IB_COLOR_TEXT);
    lv_color_t black = IB_C(IB_COLOR_BG);
    lv_color_t idle = IB_C(ROW_TEXT);
    const lv_font_t *font = &lv_font_montserrat_14;

    if (s_count == 0) {
        ib_fx_text(&fx, ROW_X + ROW_W / 2, row_y(0) + ROW_H / 2, "(empty)", font, IB_C(IB_COLOR_RING),
                   LV_OPA_COVER);
        return;
    }

    // 滚动条:总项数超过可见行数才显示滑块。
    int32_t track_h = IB_UI_LIST_ROWS * ROW_PITCH - (ROW_PITCH - ROW_H);
    ib_fx_rect(&fx, TRACK_X, row_y(0), TRACK_W, track_h, 1, IB_C(IB_COLOR_SURFACE), LV_OPA_COVER);
    if (s_n > IB_UI_LIST_ROWS) {
        int32_t thumb = track_h * IB_UI_LIST_ROWS / s_n;
        if (thumb < 12) thumb = 12;
        int32_t max_top = s_n - IB_UI_LIST_ROWS;
        int32_t top = s_top > max_top ? max_top : s_top;
        int32_t y = row_y(0) + (track_h - thumb) * top / max_top;
        ib_fx_rect(&fx, TRACK_X, y, TRACK_W, thumb, 1, IB_C(IB_COLOR_TEXT_DIM), LV_OPA_COVER);
    }

    int32_t top = LV_MIN(s_lead, s_trail) / 16, bottom = LV_MAX(s_lead, s_trail) / 16 + ROW_H;
    if (s_target >= 0) ib_fx_rect(&fx, ROW_X, top, ROW_W, bottom - top, ROW_H / 2, white, LV_OPA_COVER);

    for (int i = 0; i < s_count; i++) {
        int32_t y = row_y(i);
        int32_t overlap = s_target >= 0 ? LV_MIN(bottom, y + ROW_H) - LV_MAX(top, y) : 0;
        bool on = overlap * 2 > ROW_H;
        ib_fx_text_left(&fx, ROW_X + ROW_PAD, y + ROW_H / 2, s_rows[i], font, on ? black : idle, LV_OPA_COVER);
    }
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_title = ib_caption_create(root, IB_COLOR_TEXT_DIM, ib_font_top(&lv_font_montserrat_12, TITLE_CY), ROW_W, 2);
    lv_obj_set_style_text_align(s_title, LV_TEXT_ALIGN_LEFT, 0);
    lv_label_set_long_mode(s_title, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_align(s_title, LV_ALIGN_TOP_LEFT, ROW_X, ib_font_top(&lv_font_montserrat_12, TITLE_CY));
    s_fx = ib_fx_create(root, 0, FX_Y, IB_UI_CONTENT_W, FX_H, fx_draw, NULL);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    const ib_ui_list_t *l = &ctx->list;
    size_t n = 0;
    for (; l->title[n] && n + 1 < sizeof(s_title_text); n++) s_title_text[n] = (char)toupper((unsigned char)l->title[n]);
    s_title_text[n] = '\0';
    lv_label_set_text_static(s_title, s_title_text);
    s_count = l->rows > IB_UI_LIST_ROWS ? IB_UI_LIST_ROWS : l->rows;
    s_n = l->n;
    s_top = l->top;
    for (int i = 0; i < s_count; i++) {
        ib_text_fit(l->items[i], &lv_font_montserrat_14, ROW_W - 2 * ROW_PAD, s_rows[i], sizeof(s_rows[i]));
    }
    int32_t row = (int32_t)l->sel - (int32_t)l->top;
    bool was_hidden = s_target < 0;
    s_target = (row >= 0 && row < s_count) ? row : -1;
    if (s_target >= 0 && was_hidden) s_lead = s_trail = row_y(s_target) * 16;     // 刚出现时直接就位,不从别处滑入
    lv_obj_invalidate(s_fx);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    s_target = -1;
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    if (s_target < 0) return;
    int32_t goal = row_y(s_target) * 16;
    if (s_lead == goal && s_trail == goal) return;              // 已就位,不重绘
    s_lead += (goal - s_lead) * 45 / 100;
    s_trail += (goal - s_trail) * 25 / 100;
    if (LV_ABS(goal - s_lead) < 16) s_lead = goal;
    if (LV_ABS(goal - s_trail) < 16) s_trail = goal;
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_list = { create, enter, update, frame };
