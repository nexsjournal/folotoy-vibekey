// main/ib_ui_statusbar.c: 状态栏实现(见 ib_ui_statusbar.h)。
#include "ib_ui_statusbar.h"

#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#include <stdio.h>

#define BLINK_MS     1000

static lv_obj_t *s_link;            // 链路文字
static lv_obj_t *s_rec_group;       // 红点 + 计时
static lv_obj_t *s_rec_dot;
static lv_obj_t *s_rec_time;
static lv_obj_t *s_live;            // LIVE 徽章(自绘)
static lv_obj_t *s_pct;             // 电量百分比(含充电闪电)
static lv_obj_t *s_batt;            // 图形电池(自绘)

static ib_bar_mode_t s_mode;
static uint32_t s_rec_start;
static int s_rec_shown_s = -1;
static int s_soc = -1;
static bool s_charging;
static int32_t s_blink;             // 0..IB_P_ONE,闪烁圆点亮度
static char s_pct_text[16];
static char s_time_text[8];

static void rec_dot_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    lv_opa_t a = ib_opa_scale(255, 300 + s_blink * 724 / IB_P_ONE);
    ib_fx_circle(&fx, 6, 12, 7, IB_C(IB_COLOR_REC), ib_opa_scale(70, s_blink));   // 柔光
    ib_fx_circle(&fx, 6, 12, 4, IB_C(IB_COLOR_REC), a);
}

static void live_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    lv_color_t fg = IB_C(IB_COLOR_TEXT);
    ib_fx_frame(&fx, 0, 0, fx.w, fx.h, fx.h / 2, 1, IB_C(IB_COLOR_TEXT_DIM), LV_OPA_COVER);
    ib_fx_circle(&fx, 11, fx.h / 2, 3, ib_gray_lerp(0x484848, IB_COLOR_TEXT, s_blink), LV_OPA_COVER);
    ib_fx_text(&fx, 34, fx.h / 2, "LIVE", &lv_font_montserrat_12, fg, LV_OPA_COVER);
}

static void batt_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    // 电池外壳 22 x 11,正极触点 2 x 5。
    const int32_t x = 2, y = 7, w = 22, h = 11;
    lv_color_t shell = IB_C(IB_COLOR_TEXT_DIM);
    ib_fx_frame(&fx, x, y, w, h, 3, 1, shell, LV_OPA_COVER);
    ib_fx_rect(&fx, x + w + 1, y + 3, 2, h - 6, 1, shell, LV_OPA_COVER);
    if (s_soc >= 0) {
        int32_t fw = (w - 4) * s_soc / 100;
        if (fw < 2) fw = 2;
        uint32_t c = s_soc <= 20 && !s_charging ? IB_COLOR_TEXT_DIM : IB_COLOR_TEXT;   // 单色:低电量变灰
        ib_fx_rect(&fx, x + 2, y + 2, fw, h - 4, 1, IB_C(c), LV_OPA_COVER);
    }
}

void ib_bar_create(lv_obj_t *screen)
{
    s_link = lv_label_create(screen);
    lv_obj_set_style_text_font(s_link, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(s_link, IB_C(IB_COLOR_TEXT_DIM), 0);
    lv_obj_set_pos(s_link, 10, 4);
    lv_label_set_text_static(s_link, "");

    s_rec_group = ib_box_create(screen, 6, 0, 90, IB_UI_BAR_H);
    s_rec_dot = ib_fx_create(s_rec_group, 0, 0, 14, IB_UI_BAR_H, rec_dot_draw, NULL);
    s_rec_time = lv_label_create(s_rec_group);
    lv_obj_set_style_text_font(s_rec_time, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(s_rec_time, IB_C(IB_COLOR_TEXT), 0);
    lv_obj_set_pos(s_rec_time, 18, 4);
    lv_label_set_text_static(s_rec_time, "00:00");
    lv_obj_add_flag(s_rec_group, LV_OBJ_FLAG_HIDDEN);

    s_live = ib_fx_create(screen, 8, 3, 58, 18, live_draw, NULL);
    lv_obj_add_flag(s_live, LV_OBJ_FLAG_HIDDEN);

    s_pct = lv_label_create(screen);
    lv_obj_set_style_text_font(s_pct, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(s_pct, IB_C(IB_COLOR_TEXT), 0);
    lv_obj_set_style_text_align(s_pct, LV_TEXT_ALIGN_RIGHT, 0);
    lv_obj_set_width(s_pct, 80);
    lv_obj_set_pos(s_pct, 124, 4);
    lv_label_set_text_static(s_pct, "");

    s_batt = ib_fx_create(screen, 206, 0, 30, IB_UI_BAR_H, batt_draw, NULL);

}

void ib_bar_set_link(ib_ui_link_t link, bool online)
{
    const char *text = link == IB_UI_LINK_USB ? "USB" : link == IB_UI_LINK_BLE ? "BLE" : "";
    lv_label_set_text_static(s_link, text);
    lv_obj_set_style_text_color(s_link, IB_C(online ? IB_COLOR_TEXT : IB_COLOR_TEXT_DIM), 0);
}

void ib_bar_set_battery(int soc, bool charging)
{
    s_soc = soc;
    s_charging = charging;
    if (soc < 0) {
        snprintf(s_pct_text, sizeof(s_pct_text), "%s--", charging ? LV_SYMBOL_CHARGE " " : "");
    } else {
        snprintf(s_pct_text, sizeof(s_pct_text), "%s%d%%", charging ? LV_SYMBOL_CHARGE " " : "", soc);
    }
    lv_label_set_text_static(s_pct, s_pct_text);
    lv_obj_invalidate(s_batt);
}

void ib_bar_set_mode(ib_bar_mode_t mode, uint32_t now_ms)
{
    if (mode == IB_BAR_REC && s_mode != IB_BAR_REC) {
        s_rec_start = now_ms;
        s_rec_shown_s = -1;
        ib_bar_frame(now_ms);
    }
    s_mode = mode;
    if (mode == IB_BAR_NORMAL) lv_obj_remove_flag(s_link, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_link, LV_OBJ_FLAG_HIDDEN);
    if (mode == IB_BAR_REC) lv_obj_remove_flag(s_rec_group, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_rec_group, LV_OBJ_FLAG_HIDDEN);
    if (mode == IB_BAR_LIVE) lv_obj_remove_flag(s_live, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_live, LV_OBJ_FLAG_HIDDEN);
}

void ib_bar_frame(uint32_t now_ms)
{
    if (s_mode == IB_BAR_NORMAL) return;
    s_blink = ib_breath(now_ms, BLINK_MS);
    if (s_mode == IB_BAR_REC) {
        lv_obj_invalidate(s_rec_dot);
        int secs = (int)((now_ms - s_rec_start) / 1000U);
        if (secs != s_rec_shown_s) {
            s_rec_shown_s = secs;
            if (secs > 99 * 60 + 59) secs = 99 * 60 + 59;
            snprintf(s_time_text, sizeof(s_time_text), "%02d:%02d", secs / 60, secs % 60);
            lv_label_set_text_static(s_rec_time, s_time_text);
        }
    } else {
        lv_obj_invalidate(s_live);
    }
}
