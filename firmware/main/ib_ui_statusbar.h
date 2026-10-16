// main/ib_ui_statusbar.h: 顶部 24 px 状态栏(UI 内部模块)。
//
// 左侧:平时显示链路(USB / BLE);录音时换成闪烁红点 + 计时;字幕时换成灰框白字 LIVE 徽章(单色风格)。
// 右侧:电量百分比 + 图形电池,充电时显示闪电。按键反馈由右侧提示列承担,状态栏不再闪烁。
// 所有函数运行在 LVGL 任务或持有 LVGL 锁的任务里。
#pragma once

#include "ib_ui.h"
#include "lvgl.h"

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    IB_BAR_NORMAL = 0,
    IB_BAR_REC,
    IB_BAR_LIVE,
} ib_bar_mode_t;

void ib_bar_create(lv_obj_t *screen);
void ib_bar_set_link(ib_ui_link_t link, bool online);
void ib_bar_set_battery(int soc, bool charging);
// 切换左侧显示;进入 IB_BAR_REC 时计时从 now_ms 开始。
void ib_bar_set_mode(ib_bar_mode_t mode, uint32_t now_ms);
// 逐帧:闪烁圆点与录音计时。
void ib_bar_frame(uint32_t now_ms);
