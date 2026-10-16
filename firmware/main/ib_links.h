// main/ib_links.h: 每条链路(USB / BLE)上 Mac 是否在线(纯逻辑,由 tests/test_ib_keys.c 一并测试)。
//
// 规则(docs/protocol.md):收到任何合法命令即刷新该链路;15 秒没收到命令、收到 bye、USB 拔线或
// BLE 断开 / 取消订阅时该链路离线。两条链路独立跟踪:Mac 切到 USB 后直接断开 BLE 而不发 bye,
// 只要 USB 仍在通信设备就保持在线。
#pragma once

#include "ib_link.h"

#include <stdbool.h>
#include <stdint.h>

#define IB_LINK_TIMEOUT_MS 15000

typedef struct {
    int64_t seen_ms[IB_LINK_COUNT];     // 最近一次收到命令的时刻;0 表示离线
} ib_links_t;

void ib_links_init(ib_links_t *l);
// now_ms 必须 > 0(调用方用开机后的毫秒数 + 1 之类保证)。
void ib_links_seen(ib_links_t *l, ib_link_t link, int64_t now_ms);
void ib_links_drop(ib_links_t *l, ib_link_t link);
bool ib_links_alive(const ib_links_t *l, ib_link_t link, int64_t now_ms);
bool ib_links_any(const ib_links_t *l, int64_t now_ms);
// 优先 USB;都离线时返回 IB_LINK_COUNT。
ib_link_t ib_links_preferred(const ib_links_t *l, int64_t now_ms);
