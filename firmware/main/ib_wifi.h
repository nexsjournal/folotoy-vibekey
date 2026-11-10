// Wi-Fi 局域网链路：USB 配网、NVS 保存、mDNS 发现、TLS-PSK 加密双向流。
#pragma once
#include "esp_err.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef void (*ib_wifi_line_cb_t)(const char *, size_t);
typedef void (*ib_wifi_link_cb_t)(bool);
esp_err_t ib_wifi_start(ib_wifi_line_cb_t line, ib_wifi_link_cb_t link);
// 本轮启动是否使用 Wi-Fi；有配网记录时不启动 BLE，给音频和 TLS 保留内存。
bool ib_wifi_is_configured(void);
// 已入网并取得 IP；BLE 回退只等待此前阶段，不在 TLS 会话失败时反复重启。
bool ib_wifi_is_ready(void);
// Wi-Fi 连续失败时重启到 BLE 单栈模式；标记保存在 RTC，断电后回到自动 Wi-Fi。
bool ib_wifi_ble_fallback_requested(void);
// 用户主动选择蓝牙；插回 USB 也不自动切回 Wi-Fi。
bool ib_wifi_ble_manual_requested(void);
void ib_wifi_request_ble_fallback(void);
void ib_wifi_request_bluetooth(void);
void ib_wifi_clear_ble_fallback(void);
// 识别 wifi 命令后返回 true；凭据从不输出日志。
// allow_provisioning=false 时只接受 list/select/remove/ble，新增与清除仍必须走 USB。
bool ib_wifi_handle_control_line(const char *line, size_t len, bool allow_provisioning);
// USB 收包入口：允许新增与清除配网。
bool ib_wifi_handle_usb_line(const char *line, size_t len);
void ib_wifi_send(const uint8_t *data, size_t len);
void ib_wifi_send_audio(const uint8_t *data, size_t len);
// USB 重连握手时补发真实状态，不能让 Mac 长期保留旧的 connecting。
void ib_wifi_report_status(void);
// 设备离线页使用：只读取 / 切换本机 NVS 中的网络名，不向屏幕暴露密码或 PSK。
size_t ib_wifi_network_count(void);
size_t ib_wifi_active_network(void);
bool ib_wifi_network_name(size_t index, char *out, size_t cap);
// 写入 active 后由调用方延迟重启；返回 false 表示下标非法或 NVS 写入失败。
bool ib_wifi_select_network(size_t index);
