// main/ib_ui_proc.c: PROC 页:识别 / LLM 处理中(docs/device-ui.md「PROC」)。
//
// 从 REC 直切而来时,声波先按行塌缩成一条线(ib_ui_dots),之后线变暗,一段 5 颗点长的亮光在线上来回扫
// (单程 1.2 s,ease-in-out):处理中。没有文字。
// 这时上一句还没处理完,右侧提示列是禁用色(ib_ui.c),按 OK 会得到"不可用"反馈,不会开始新的一句。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#define PASS_MS     1200                // 扫描光单程
#define HALO        3                   // 光带半宽(列)

static lv_obj_t *s_fx;
static int32_t s_head = -1;             // 扫描光位置(列,x16)

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    uint32_t now = lv_tick_get();
    if (!ib_dots_settled(now) || s_head < 0) {
        ib_dots_draw(&fx, now, 0);
        return;
    }
    for (int c = 0; c < IB_DOTS_COLS; c++) {
        int32_t dist = LV_ABS(c * 16 - s_head);                 // x16
        int32_t glow = dist < HALO * 16 ? (HALO * 16 - dist) * IB_P_ONE / (HALO * 16) : 0;
        lv_color_t col = ib_gray_lerp(IB_COLOR_MUTE, IB_COLOR_TEXT, glow);
        ib_dots_dot(&fx, ib_dots_x(c), ib_dots_y(IB_DOTS_ROW_MID), col, dist < 8 ? 1 : 0);
    }
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, IB_DOTS_BOX_Y, IB_UI_CONTENT_W, IB_DOTS_BOX_H, fx_draw, NULL);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    (void)ctx;
}

static void enter(const ib_ui_ctx_t *ctx)
{
    ib_dots_t line;
    ib_dots_line(&line, IB_DOT_DIM, IB_DOT_DIM);
    ib_dots_enter(ctx, &line);
    s_head = -1;
}

static void frame(const ib_ui_ctx_t *ctx)
{
    if (ib_dots_settled(ctx->now_ms)) {
        // 从左端开始来回扫:偶数趟向右,奇数趟向左。
        uint32_t t = ctx->now_ms - ib_dots_settle_ms();
        int32_t p = ib_ease_in_out_sine(ib_progress(t % PASS_MS, 0, PASS_MS));
        if ((t / PASS_MS) % 2) p = IB_P_ONE - p;
        s_head = (IB_DOTS_COLS - 1) * 16 * p / IB_P_ONE;
    }
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_proc = { create, enter, update, frame };
