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
// 仅由 USB 收包入口调用。识别 wifi 命令后返回 true；凭据从不输出日志。
bool ib_wifi_handle_usb_line(const char *line, size_t len);
void ib_wifi_send(const uint8_t *data, size_t len);
// USB 重连握手时补发真实状态，不能让 Mac 长期保留旧的 connecting。
void ib_wifi_report_status(void);
