// main/ib_links.h: 每条链路(USB / BLE)上 Mac 是否在线(纯逻辑,由 tests/test_ib_keys.c 一并测试)。
//
// 规则(docs/protocol.md):收到任何合法命令即刷新该链路;15 秒没收到命令、收到 bye、USB 拔线(去抖 1 s)或
// BLE 断开 / 取消订阅时该链路离线。两条链路独立跟踪:Mac 切到 USB 后直接断开 BLE 而不发 bye,
// 只要 USB 仍在通信设备就保持在线。
#pragma once

#include "ib_link.h"

#include <stdbool.h>
#include <stdint.h>

#define IB_LINK_TIMEOUT_MS 15000

// USB 主机"不在位"要连续这么久才确认(去抖)。
// ESP-IDF 的 usb_serial_jtag_is_connected() 只是"约 4 ms 没收到 USB SOF 帧就判离线",没有去抖:
// Mac 睡眠 / USB 总线挂起、SOF 短暂中断都会读到 false,直接据此离线会闪出 OFFLINE 页并点亮屏幕。
// 取 1 s:真正拔线后 Mac 本来就要约 1 s 才重新打开串口(DeviceLink.usbRetryDelay),
// 离线页晚 1 s 出现对用户没有影响;期间收到 USB 命令说明主机仍在,计时从命令时刻重新开始。
#define IB_USB_ABSENT_CONFIRM_MS 1000

typedef struct {
    int64_t seen_ms[IB_LINK_COUNT];     // 最近一次收到命令的时刻;0 表示离线
    bool usb_present;                   // 去抖后的 USB 主机在位状态
    int64_t usb_absent_since;           // 在位期间首次读到"不在位"的时刻;0 表示没有待确认的不在位
} ib_links_t;

void ib_links_init(ib_links_t *l);
// now_ms 必须 > 0(调用方用开机后的毫秒数 + 1 之类保证)。
void ib_links_seen(ib_links_t *l, ib_link_t link, int64_t now_ms);
void ib_links_drop(ib_links_t *l, ib_link_t link);
bool ib_links_alive(const ib_links_t *l, ib_link_t link, int64_t now_ms);
bool ib_links_any(const ib_links_t *l, int64_t now_ms);
// 优先 USB;都离线时返回 IB_LINK_COUNT。
ib_link_t ib_links_preferred(const ib_links_t *l, int64_t now_ms);

// USB 主机在位去抖:raw_present 为本次轮询读到的原始值(ib_usb_host_present()),返回去抖后的在位状态。
// 读到在位立即返回 true;由在位变不在位时,要连续 IB_USB_ABSENT_CONFIRM_MS 读到不在位、且期间没有经
// ib_links_seen() 收到 USB 命令才返回 false。只做判定,不清除 USB 链路(由调用方在返回 false 时 drop)。
// 需周期调用(ib_app 每 100 ms 一次);now_ms 必须 > 0。
bool ib_links_usb_present(ib_links_t *l, bool raw_present, int64_t now_ms);
