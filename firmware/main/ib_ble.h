// main/ib_ble.h: BLE 链路:NimBLE GATT 外设,广播名 "InputBetter",不配对。
#pragma once

#include "esp_err.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// 每收到完整一行命令调用一次,运行在 NimBLE host 任务中,必须快速返回。
typedef void (*ib_ble_line_cb_t)(const char *line, size_t len);
// Mac 订阅 / 取消订阅事件特征(含断开连接)时调用,运行在 NimBLE host 任务中。
typedef void (*ib_ble_link_cb_t)(bool subscribed);

// 初始化 NimBLE,注册 GATT 服务并开始可连接广播。
esp_err_t ib_ble_start(ib_ble_line_cb_t on_line, ib_ble_link_cb_t on_link);

// 通过 Events 特征 Notify 一行 JSON,按 MTU 分片;未连接或未订阅时丢弃。任意任务可调用。
void ib_ble_send(const char *data, size_t len);

// 通过 Audio In 特征 Notify 一个二进制帧(含帧头,须不超过 MTU-3);未订阅时丢弃,不重试。任意任务可调用。
void ib_ble_send_audio(const uint8_t *frame, size_t len);

// 麦克风上行期间把从机延迟降到 0,结束后恢复省电参数。任意任务可调用。
void ib_ble_set_audio_mode(bool on);

// 切到 30 秒快速广播(USB 拔线后让 Mac 尽快发现设备);已连接时忽略。任意任务可调用。
void ib_ble_boost_advertising(void);

// 当前协商的 ATT MTU;未连接返回 0。
uint16_t ib_ble_mtu(void);
