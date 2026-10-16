// main/ib_usb.h: USB Serial/JTAG 链路(与 ESP-IDF 控制台日志共用 ESP32-C3 原生 USB)。
#pragma once

#include "esp_err.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// 每收到完整一行调用一次,运行在 USB 接收任务中,必须快速返回。
typedef void (*ib_usb_line_cb_t)(const char *line, size_t len);

// 安装 USB Serial/JTAG 驱动,让 VFS 控制台走驱动,并启动接收任务。
esp_err_t ib_usb_start(ib_usb_line_cb_t on_line);

// 发送一整行文本。没接主机时直接丢弃;主机不读取时驱动在超时后丢弃,不会长期阻塞。
void ib_usb_send(const char *data, size_t len);

// 发送一个完整二进制帧(含帧头),一次写入驱动发送环,发送环放不下时最多等 20 ms 后丢弃。任意任务可调用。
void ib_usb_send_bin(const uint8_t *frame, size_t len);

// 是否有 USB 主机在轮询本设备(按 SOF 判断);拔线后几毫秒内变 false。
bool ib_usb_host_present(void);
