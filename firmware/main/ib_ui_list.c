// main/ib_ui_list.c: LIST 页:Mac 驱动的列表(例如应用切换器)。
//
// 设备只负责显示:标题、最多 6 行圆角胶囊、选中项、左侧滚动条。选中项与滚动位置都由 Mac 的 list 命令决定,
// 按键仍原样上报给 Mac。
// 布局(页面坐标,只用左侧内容区):
//   标题    Montserrat 14 灰色,左对齐 @ y=6
//   行      x=14、宽 内容区-20、高 34、间距 40,首行 y=30;未选中为深灰底(#181818)白字,选中为白底黑字
//   滚动条  x=4 的 3 px 细轨道,总项数超过可见行数时显示滑块(右侧是按键提示列,所以放左边)
// 选中高亮每帧向目标行靠近 35%(约 150 ms 滑到位),文字颜色按高亮覆盖过半切换。
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define ROW_X       14
#define ROW_W       (IB_UI_CONTENT_W - ROW_X - 6)
#define ROW_H       34
#define ROW_PITCH   40
#define ROW_Y0      30
#define ROW_PAD     12          // 行内文字左边距
#define FX_Y        (ROW_Y0 - 2)
#define FX_H        (IB_UI_LIST_ROWS * ROW_PITCH + 4)
#define TRACK_X     4
#define TRACK_W     3
#define TEXT_MAX    28

static lv_obj_t *s_title;
static lv_obj_t *s_fx;
static char s_rows[IB_UI_LIST_ROWS][TEXT_MAX];  // 截断后的显示文本(绘制回调读取)
static uint8_t s_count;
static uint16_t s_n, s_top;
static int32_t s_target = -1;       // 选中行在可见区内的序号,-1 表示不在可见区
static int32_t s_hl_y = 0;          // 高亮当前纵坐标(x16,控件坐标)

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
    const lv_font_t *font = &lv_font_montserrat_14;

    if (s_count == 0) {
        ib_fx_text(&fx, ROW_X + ROW_W / 2, row_y(0) + ROW_H / 2, "(empty)", font, IB_C(IB_COLOR_TEXT_DIM),
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
        ib_fx_rect(&fx, TRACK_X, y, TRACK_W, thumb, 1, ib_gray(0xA0), LV_OPA_COVER);
    }

    for (int i = 0; i < s_count; i++) {
        ib_fx_rect(&fx, ROW_X, row_y(i), ROW_W, ROW_H, ROW_H / 2, IB_C(IB_COLOR_SURFACE), LV_OPA_COVER);
    }
    int32_t hl = s_hl_y / 16;
    if (s_target >= 0) ib_fx_rect(&fx, ROW_X, hl, ROW_W, ROW_H, ROW_H / 2, white, LV_OPA_COVER);

    for (int i = 0; i < s_count; i++) {
        int32_t y = row_y(i);
        int32_t overlap = s_target >= 0 ? ROW_H - LV_ABS(hl - y) : 0;
        bool on = overlap * 2 > ROW_H;
        ib_fx_text_left(&fx, ROW_X + ROW_PAD, y + ROW_H / 2, s_rows[i], font, on ? black : white, LV_OPA_COVER);
    }
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_title = lv_label_create(root);
    lv_obj_set_style_text_font(s_title, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(s_title, IB_C(IB_COLOR_TEXT_DIM), 0);
    lv_obj_set_width(s_title, ROW_W);
    lv_label_set_long_mode(s_title, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_pos(s_title, ROW_X + 4, 6);
    lv_label_set_text_static(s_title, "");
    s_fx = ib_fx_create(root, 0, FX_Y, IB_UI_CONTENT_W, FX_H, fx_draw, NULL);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    const ib_ui_list_t *l = &ctx->list;
    lv_label_set_text(s_title, l->title);
    s_count = l->rows > IB_UI_LIST_ROWS ? IB_UI_LIST_ROWS : l->rows;
    s_n = l->n;
    s_top = l->top;
    for (int i = 0; i < s_count; i++) {
        ib_text_fit(l->items[i], &lv_font_montserrat_14, ROW_W - 2 * ROW_PAD, s_rows[i], sizeof(s_rows[i]));
    }
    int32_t row = (int32_t)l->sel - (int32_t)l->top;
    bool was_hidden = s_target < 0;
    s_target = (row >= 0 && row < s_count) ? row : -1;
    if (s_target >= 0 && was_hidden) s_hl_y = row_y(s_target) * 16;     // 刚出现时直接就位,不从别处滑入
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
    int32_t d = goal - s_hl_y;
    if (d == 0) return;                         // 已就位,不重绘
    int32_t step = d * 35 / 100;
    if (step == 0) step = d > 0 ? 1 : -1;
    s_hl_y += step;
    if (LV_ABS(goal - s_hl_y) < 8) s_hl_y = goal;
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_list = { create, enter, update, frame };
