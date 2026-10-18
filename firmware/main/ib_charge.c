// main/ib_charge.c: 充电状态推断与"已充满"判定实现(见 ib_charge.h)。
#include "ib_charge.h"

void ib_charge_init(ib_charge_t *c)
{
    c->candidate_since = 0;
    c->full = false;
}

ib_charge_view_t ib_charge_update(ib_charge_t *c, bool usb_present, int soc, int mv, int64_t now_ms)
{
    ib_charge_view_t view = { .soc = soc, .charging = false };
    // 读数未知(电量计没装好或这次 I2C 失败):不改判定状态,下次读到有效值再继续。
    if (soc < 0 || mv < 0) return view;

    if (c->full) {
        // 已充满只由电压 / SOC 退出,与 USB 在位无关;退出电压比进入低 50 mV(回差),
        // 避免充电 IC 终止后电压回落导致来回跳。
        if (soc >= IB_CHARGE_FULL_SOC_MIN && mv >= IB_CHARGE_FULL_EXIT_MV) {
            view.soc = 100;
            return view;
        }
        ib_charge_init(c);
    }

    if (!usb_present) {
        // 没接 USB:不充电,确认计时清零。
        c->candidate_since = 0;
        return view;
    }

    if (soc >= IB_CHARGE_FULL_SOC_MIN && mv >= IB_CHARGE_FULL_MV) {
        if (c->candidate_since == 0) c->candidate_since = now_ms > 0 ? now_ms : 1;
        if (now_ms - c->candidate_since >= IB_CHARGE_FULL_CONFIRM_MS) {
            c->full = true;
            view.soc = 100;
            return view;
        }
    } else {
        c->candidate_since = 0;
    }

    view.charging = soc < 100;
    return view;
}
