// main/ib_ui_statusbar.c: 状态栏实现(见 ib_ui_statusbar.h;docs/device-ui.md「状态栏」)。
//
// 全部 12 px 小字加字距,中灰,不与页面主文字争抢:
//   左:链路 USB / BLE(在线中灰、离线深灰);录音时换成脉动红点 + 计时;字幕时换成闪烁白点 + LIVE(无边框)
//   右:电量是 5 颗小圆点(每颗 20%,与界面的点阵语言一致);≤20% 且未充电时唯一亮着的点变红(唯一的彩色提醒),
//       充电时点从左到右循环点亮;百分比数字只在低电量或充电时出现(平时看点就够了)
#include "ib_ui_statusbar.h"

#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#include <stdio.h>

#define BLINK_MS     1000
#define LOW_SOC      20             // 低电量阈值(%):点变红、显示百分比
#define BATT_DOTS    5
#define BATT_DOT     4              // 点 4x4,间距 6:屏幕 x 208..236
#define BATT_PITCH   6
#define CHARGE_MS    1000           // 充电时循环点亮一轮

static lv_obj_t *s_link;            // 链路文字
static lv_obj_t *s_rec_group;       // 红点 + 计时
static lv_obj_t *s_rec_dot;
static lv_obj_t *s_rec_time;
static lv_obj_t *s_live;            // LIVE:闪烁白点 + 文字
static lv_obj_t *s_live_dot;
static lv_obj_t *s_pct;             // 电量百分比(含充电闪电)
static lv_obj_t *s_batt;            // 图形电池(自绘)

static ib_bar_mode_t s_mode;
static uint32_t s_rec_start;
static int s_rec_shown_s = -1;
static int s_soc = -1;
static bool s_charging;
static int32_t s_blink;             // 0..IB_P_ONE,闪烁圆点亮度
static int s_charge_step = -1;      // 充电动画当前点亮到第几颗
static char s_pct_text[16];
static char s_time_text[8];

// 录音红点:圆心 (14, 12) r=4,不透明度 100% ↔ 40% 正弦脉动(控件在屏幕 x 6,所以控件内圆心 x=8)。
static void rec_dot_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    ib_fx_circle(&fx, 8, 12, 4, IB_C(IB_COLOR_REC), ib_opa_scale(255, IB_P_ONE - s_blink * 6 / 10));
}

// LIVE 白点:圆心 (14, 12) r=3,#F0F0F0 ↔ #505050 闪烁。
static void live_dot_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    ib_fx_circle(&fx, 8, 12, 3, ib_gray_lerp(IB_COLOR_RING, IB_COLOR_TEXT, IB_P_ONE - s_blink), LV_OPA_COVER);
}

static void batt_draw(lv_event_t *e)
{
    ib_fx_t fx;
    ib_fx_begin(&fx, e);
    // 控件在屏幕 x 206,点心依次在 x 210、216 … 234,y 12。
    int lit = s_soc < 0 ? 0 : (s_soc + 19) / 20;
    if (lit > BATT_DOTS) lit = BATT_DOTS;
    if (s_charging && s_charge_step >= 0) lit = s_charge_step + 1;           // 充电:循环点亮
    bool low = s_soc >= 0 && s_soc <= LOW_SOC && !s_charging;
    for (int i = 0; i < BATT_DOTS; i++) {
        lv_color_t c = i >= lit ? IB_C(IB_COLOR_MUTE) : low ? IB_C(IB_COLOR_REC) : IB_C(IB_COLOR_TEXT);
        ib_fx_rect(&fx, 2 + i * BATT_PITCH, 12 - BATT_DOT / 2, BATT_DOT, BATT_DOT, BATT_DOT / 2, c, LV_OPA_COVER);
    }
}

void ib_bar_create(lv_obj_t *screen)
{
    // 12 px 字体行高约 15:顶部 y=5 时文字垂直居中在 y≈12。
    s_link = ib_caption_create(screen, IB_COLOR_TEXT_MID, 0, 80, 1);
    lv_obj_set_style_text_align(s_link, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_align(s_link, LV_ALIGN_TOP_LEFT, 10, 5);

    s_rec_group = ib_box_create(screen, 6, 0, 90, IB_UI_BAR_H);
    s_rec_dot = ib_fx_create(s_rec_group, 0, 0, 16, IB_UI_BAR_H, rec_dot_draw, NULL);
    s_rec_time = lv_label_create(s_rec_group);
    lv_obj_set_style_text_font(s_rec_time, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(s_rec_time, IB_C(IB_COLOR_TEXT), 0);
    lv_obj_set_pos(s_rec_time, 18, 4);
    lv_label_set_text_static(s_rec_time, "00:00");
    lv_obj_add_flag(s_rec_group, LV_OBJ_FLAG_HIDDEN);

    s_live = ib_box_create(screen, 6, 0, 80, IB_UI_BAR_H);
    s_live_dot = ib_fx_create(s_live, 0, 0, 16, IB_UI_BAR_H, live_dot_draw, NULL);
    lv_obj_t *live_text = ib_caption_create(s_live, IB_COLOR_TEXT, 0, 60, 2);
    lv_obj_set_style_text_align(live_text, LV_TEXT_ALIGN_LEFT, 0);
    lv_obj_align(live_text, LV_ALIGN_TOP_LEFT, 18, 5);
    lv_label_set_text_static(live_text, "LIVE");
    lv_obj_add_flag(s_live, LV_OBJ_FLAG_HIDDEN);

    // 电量百分比右对齐到 x=202。
    s_pct = ib_caption_create(screen, IB_COLOR_TEXT_MID, 0, 80, 1);
    lv_obj_set_style_text_align(s_pct, LV_TEXT_ALIGN_RIGHT, 0);
    lv_obj_align(s_pct, LV_ALIGN_TOP_LEFT, 202 - 80, 5);

    s_batt = ib_fx_create(screen, 206, 0, 30, IB_UI_BAR_H, batt_draw, NULL);
}

void ib_bar_set_link(ib_ui_link_t link, bool online)
{
    const char *text = link == IB_UI_LINK_USB ? "USB" : link == IB_UI_LINK_BLE ? "BLE" : "";
    lv_label_set_text_static(s_link, text);
    lv_obj_set_style_text_color(s_link, IB_C(online ? IB_COLOR_TEXT_MID : IB_COLOR_RING), 0);
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
    // 百分比只在低电量或充电时显示。
    if (charging || (soc >= 0 && soc <= LOW_SOC)) lv_obj_remove_flag(s_pct, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(s_pct, LV_OBJ_FLAG_HIDDEN);
    if (!charging) s_charge_step = -1;
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
    if (s_charging) {
        int step = (int)(now_ms % CHARGE_MS * BATT_DOTS / CHARGE_MS);
        if (step != s_charge_step) {
            s_charge_step = step;
            lv_obj_invalidate(s_batt);
        }
    }
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
        lv_obj_invalidate(s_live_dot);
    }
}
