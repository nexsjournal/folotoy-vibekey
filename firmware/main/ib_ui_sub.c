// main/ib_ui_sub.c: SUB 页:字幕运行中(docs/device-ui.md「SUB」;状态栏左侧由 ib_ui_statusbar 显示 LIVE)。
//
//   进入    从其它点阵页直切而来时,点先重排成一条线(ib_ui_dots),声波再从线上长出
//   声波    点阵声波(ib_ui_wave,scroll 排布):白色活柱在最右列,历史柱每 100 ms 向左跳一格、越远越暗
//           (字幕是"听",不用录音红)
//   应用名  Montserrat 20,中心 y=220,超长显示省略号(msg)
// STOP / TRANSLATE / HIDE 等操作由右侧按键提示列(Mac 下发)显示,页面不写操作文字。
#include "ib_ui_dots.h"
#include "ib_ui_gfx.h"
#include "ib_ui_page.h"
#include "ib_ui_wave.h"

#define APP_CY      (220 - IB_UI_BAR_H)
#define GROW_MS     300

static lv_obj_t *s_fx;
static lv_obj_t *s_app;
static bool s_wave_on;
static uint32_t s_wave_ms;

static void fx_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    if (s_wave_on) ib_wave_draw(&fx, ib_wave_shared());
    else ib_dots_draw(&fx, lv_tick_get(), 0);
}

static lv_obj_t *create(lv_obj_t *parent, const ib_ui_ctx_t *ctx)
{
    (void)ctx;
    lv_obj_t *root = ib_box_create(parent, 0, 0, IB_UI_CONTENT_W, IB_UI_PAGE_H);
    s_fx = ib_fx_create(root, 0, IB_DOTS_BOX_Y, IB_UI_CONTENT_W, IB_DOTS_BOX_H, fx_draw, NULL);
    s_app = ib_label_create(root, &lv_font_montserrat_20, IB_COLOR_TEXT, ib_font_top(&lv_font_montserrat_20, APP_CY),
                            IB_UI_CONTENT_W - 16);
    lv_label_set_long_mode(s_app, LV_LABEL_LONG_MODE_DOTS);
    return root;
}

static void update(const ib_ui_ctx_t *ctx)
{
    lv_label_set_text(s_app, ctx->msg);
}

static void enter(const ib_ui_ctx_t *ctx)
{
    ib_dots_t line;
    ib_dots_line(&line, IB_DOT_WHITE, IB_DOT_WHITE);
    ib_dots_enter(ctx, &line);
    s_wave_on = false;
    update(ctx);
}

static void frame(const ib_ui_ctx_t *ctx)
{
    ib_wave_t *w = ib_wave_shared();
    if (!s_wave_on && ib_dots_settled(ctx->now_ms)) {
        s_wave_on = true;
        s_wave_ms = ctx->now_ms;
        ib_wave_reset(w, IB_WAVE_SCROLL, ctx->now_ms);
    }
    if (s_wave_on) {
        ib_wave_step(w, ctx->level_smooth, ib_ease_out_cubic(ib_progress(ctx->now_ms, s_wave_ms, GROW_MS)), ctx->now_ms);
    }
    lv_obj_invalidate(s_fx);
}

const ib_ui_page_t ib_ui_page_sub = { create, enter, update, frame };
