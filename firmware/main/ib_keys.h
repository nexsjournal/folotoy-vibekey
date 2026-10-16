// main/ib_keys.h: 按键事件过滤(纯逻辑,不依赖 ESP-IDF,由 tests/test_ib_keys.c 在主机上测试)。
//
// 把 BSP 的原始按下 / 松开 / 长按事件变成"要不要上报、带不带 ack":
//   - Mac 离线或屏幕熄灭时,按下只用于点亮屏幕,这次按压的 down/up/long 都不上报;
//   - 只有上报过 down 的按压,才会上报对应的 up / long(保证 Mac 收到成对的 down/up,用于按住说话);
//   - 重复的 down、没有 down 的 up/long 一律忽略(去抖之外的第二道保险);
//   - Agent 通知层正在接收按键(全屏显示)时,按下即关闭通知,这次按压的 down/up/long 都带 ack;
//   - 同一个键松开后 IB_KEYS_REPRESS_LOCKOUT_MS 内的再次按下视为触点回弹,整次忽略(down/up/long 都不报)。
//
// 去抖分两层:espressif/button 在 ADC 采样层要求连续 4 次(5 ms 一次,共 20 ms)落在同一电压窗口才改变状态,
// 滤掉单引脚三键切换时经过其它键电压窗口的瞬态;本模块再挡住超过 20 ms 的松开回弹。
// 人手连按同一键的间隔通常 > 100 ms,60 ms 锁定不会吞掉真实按键。
#pragma once

#include "ib_protocol.h"

#include <stdbool.h>
#include <stdint.h>

#define IB_KEYS_REPRESS_LOCKOUT_MS 60

typedef struct {
    bool pressed[IB_KEY_COUNT];     // 这次按压的 down 已上报
    bool ack[IB_KEY_COUNT];         // 这次按压用于关闭 Agent 通知
    bool has_up[IB_KEY_COUNT];      // 该键松开过(last_up_ms 有效)
    int64_t last_up_ms[IB_KEY_COUNT];   // 该键最近一次松开(BSP 报告的)时刻
} ib_keys_t;

typedef struct {
    bool send;              // 需要上报 key 事件
    bool ack;               // 上报时附加 "ack":1
    bool dismiss_agent;     // 需要关闭 Agent 通知
} ib_key_action_t;

void ib_keys_reset(ib_keys_t *k);

// now_ms:事件时刻(单调毫秒);online:Mac 在线;screen_dark:按下前屏幕是熄灭的;
// agent_capture:Agent 全屏通知正在显示。后两个参数只对 IB_KEY_EV_DOWN 有意义。
ib_key_action_t ib_keys_handle(ib_keys_t *k, ib_key_t key, ib_key_ev_t ev, int64_t now_ms, bool online,
                               bool screen_dark, bool agent_capture);
