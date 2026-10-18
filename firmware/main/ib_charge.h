// main/ib_charge.h: 充电状态推断与"已充满"判定(纯逻辑,由 tests/test_ib_charge.c 在主机上测试)。
//
// Passport 板上没有充电 IC 的状态引脚,CW2017 是纯电压模型电量计(没有电流采样),固件拿不到
// "正在充电 / 已充满"的真实信号,只能推断:
//   - 插着 USB 主机且电量 < 100% 视为充电中;
//   - 但 CW2017 的 SOC 在恒压段会饱和在 9x%(实测卡在 94%,电量计 profile 的满电电压与充电 IC
//     终止电压不匹配),永远到不了 100%,于是一直显示充电动画。
// 折中做法:USB 在位、SOC 不低于 IB_CHARGE_FULL_SOC_MIN、电压不低于 IB_CHARGE_FULL_MV 持续
// IB_CHARGE_FULL_CONFIRM_MS,视为已充满:不再算充电中,显示 / 上报 100%。阈值是经验值,待实测调整。
// 已充满之后只由电压 / SOC 退出(电压跌破 IB_CHARGE_FULL_EXIT_MV 或 SOC 跌破下限),与 USB 是否在位无关:
//   - USB 在位是按 SOF 判断的,Mac 睡眠时 SOF 停止但 VBUS 仍在充电,不能据此清掉判定;
//   - 真拔线后电池静置电压 ≥ 4.10 V 本来就是满的,等电压自然掉下去再回到实际读数,避免 100 → 94 跳变。
// 某次读数失败(soc 或 mv 为 -1)不改变任何判定状态,避免一次 I2C 失败就要重新等 10 分钟。
#pragma once

#include <stdbool.h>
#include <stdint.h>

// SOC 下限:只用作电压读数异常时的保护,主要依据是电压。取 90 而不是 95:实测 SOC 卡在 94%,
// 下限高于这个值判定就永远不会成立。
#define IB_CHARGE_FULL_SOC_MIN 90
// 进入"已充满"的电压:4.2 V 锂电充电在恒压段末期,带充电电流时端电压 ≥ 4.15 V。
#define IB_CHARGE_FULL_MV 4150
// 退出"已充满"的电压:比进入阈值低 50 mV 的回差。充电 IC 终止后电池电压会回落一些,
// 没有回差的话会在"已充满"和"充电中"之间来回跳(进入还要再等 10 分钟)。
#define IB_CHARGE_FULL_EXIT_MV 4100
// 条件要持续这么久才确认,避开恒流段末尾电压刚到阈值、电池其实还没满的阶段。
#define IB_CHARGE_FULL_CONFIRM_MS (10 * 60 * 1000)

typedef struct {
    int64_t candidate_since;    // 满足"进入"条件的起始时刻;0 表示当前不满足
    bool full;                  // 已确认充满
} ib_charge_t;

// 显示 / 上报用的电量与充电状态。
typedef struct {
    int soc;                    // 0...100,未知为 -1;已充满时为 100
    bool charging;
} ib_charge_view_t;

void ib_charge_init(ib_charge_t *c);

// 每次读电量后调用。usb_present 为去抖后的 USB 主机在位状态;soc / mv 为电量计原始读数(未知为 -1);
// now_ms 必须 > 0。返回应显示与上报的电量与充电状态(读数未知时为原始 soc、不算充电)。
ib_charge_view_t ib_charge_update(ib_charge_t *c, bool usb_present, int soc, int mv, int64_t now_ms);
