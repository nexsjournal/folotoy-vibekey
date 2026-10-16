// main/ib_app.h: InputBetter 应用核心:事件队列与状态机(链路在线、Mac 下发状态、按键上报、麦克风、
// Agent 通知、熄屏、电量、时钟)。屏幕绘制交给 ib_ui,链路收发交给 ib_usb / ib_ble,音频交给 ib_audio。
#pragma once

#include "bsp_button.h"
#include "esp_err.h"

#include <stdbool.h>

// 建立事件队列,启动 UI、USB、BLE、音频与应用任务。
// ui_ok=false 时不访问屏幕;battery_ok=false 时电量上报 -1。单个子系统失败只记录日志,其余照常工作。
esp_err_t ib_app_start(bool ui_ok, bool battery_ok);

// 传给 bsp_button_init() 的回调。运行在 button 组件的定时器任务中,只向队列投递事件,不阻塞。
void ib_app_on_button(bsp_btn_t btn, bsp_btn_ev_t ev, void *user);
