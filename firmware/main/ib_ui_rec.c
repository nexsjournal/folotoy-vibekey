// main/ib_ui_rec.c: REC 页:录音中(docs/device-ui.md「REC」)。
//
// 一屏只说"正在录、声音有多大":
//   进入    从 IDLE 直切而来时,模式字形的点先重排成一条线(中间那颗变成录音红,ib_ui_dots),
//           声波再从这条线上长出来(300 ms);其它情况直接从线开始
//   声波    点阵声波(ib_ui_wave,mirror 排布):中央红色活柱 = 当前音量,历史柱每 100 ms 向两侧跳一格并变暗;
//           静音时是一条点线,配合状态栏的红点与计时,安静但明显在录
//   提示    按实际按键状态提示松开或再次按 OK;翻译模式另显示 translate 图标。
// 停止 / 取消等操作由右侧按键提示列显示(Mac 下发)。逐帧只 invalidate 点阵控件。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"
#include "ib_ui_wave.h"

#define PROMPT_CY   (220 - IB_UI_BAR_H)
#define MODE_CY     (248 - IB_UI_BAR_H)
#define GROW_MS     300

static lv_obj_t *s_fx;
static lv_obj_t *s_mode;
static lv_obj_t *s_prompt;
static bool s_wave_on;              // 重排结束、声波已接管
static uint32_t s_wave_ms;

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    ib_fx_frame(&fx, 6, 4, IB_UI_CONTENT_W - 12, IB_DOTS_BOX_H - 8, 0, 1,
                IB_C(IB_COLOR_MATRIX_FRAME), LV_OPA_COVER);
    if (s_wave_on) ib_wave_draw(&fx, ib_wave_shared());
    else ib_dots_draw(&fx, lv_tick_get(), 0);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    ib_terminal_header(root, "> LISTENING", IB_COLOR_REC, IB_UI_CONTENT_W);
    s_fx = ib_fx_create(root, 0, IB_DOTS_BOX_Y, IB_UI_CONTENT_W, IB_DOTS_BOX_H, fx_draw, NULL);
    s_prompt = ib_label_create(root, &ib_terminal_font_14, IB_COLOR_TEXT,
                               ib_font_top(&ib_terminal_font_14, PROMPT_CY), IB_UI_CONTENT_W);
    s_mode = ib_label_create(root, &ib_icon_font_12, IB_COLOR_TEXT_DIM, ib_font_top(&ib_icon_font_12, MODE_CY),
                             IB_UI_CONTENT_W);
    lv_label_set_text_static(s_mode, ib_icon_glyph(IB_ICON_TRANSLATE));
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    lv_label_set_text_static(s_prompt, ctx->ok_held ? "RELEASE TO FINISH" : "PRESS OK TO STOP");
    if (ctx->mode == IB_UI_MODE_TR) lv_obj_remove_flag(s_mode, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_mode, LV_OBJ_FLAG_HIDDEN);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    ib_dots_t line;
    ib_dots_line(&line, IB_DOT_WHITE, IB_DOT_REC);
    ib_dots_enter(ctx, &line);
    s_wave_on = false;
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    ib_wave_t *w = ib_wave_shared();
    if (!s_wave_on && ib_dots_settled(ctx->now_ms)) {
        // 静音的声波就是一条点线(中间红),与重排落地的线逐像素重合,接管时没有跳变。
        s_wave_on = true;
        s_wave_ms = ctx->now_ms;
        ib_wave_reset(w, IB_WAVE_MIRROR, ctx->now_ms);
    }
    if (s_wave_on) {
        ib_wave_step(w, ctx->level_smooth, ib_ease_out_cubic(ib_progress(ctx->now_ms, s_wave_ms, GROW_MS)), ctx->now_ms);
    }
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_rec = { create, enter, update, frame };
