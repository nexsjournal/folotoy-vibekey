// tests/test_ib_charge.c: ib_charge(充电推断与"已充满"判定)主机测试。
#include "ib_charge.h"
#include "test_common.h"

#define MIN_MS (60 * 1000)

// 没接 USB 或读数未知:不算充电;接着 USB 且未满:充电中;电量计到 100 时不算充电。
static void test_basic(void)
{
    ib_charge_t c;
    ib_charge_init(&c);
    ib_charge_view_t v = ib_charge_update(&c, false, 50, 3800, 1000);
    CHECK(v.soc == 50 && !v.charging);
    v = ib_charge_update(&c, true, 50, 3900, 2000);
    CHECK(v.soc == 50 && v.charging);
    v = ib_charge_update(&c, true, -1, -1, 3000);
    CHECK(v.soc == -1 && !v.charging);
    v = ib_charge_update(&c, true, 100, 4200, 4000);
    CHECK(v.soc == 100 && !v.charging);
}

// SOC 卡在 94%、电压已到 4.15 V 以上:持续 10 分钟才判为已充满,显示 100%。
static void test_full_confirm(void)
{
    ib_charge_t c;
    ib_charge_init(&c);
    int64_t t0 = 1000;
    ib_charge_view_t v = ib_charge_update(&c, true, 94, 4180, t0);
    CHECK(v.soc == 94 && v.charging);
    v = ib_charge_update(&c, true, 94, 4180, t0 + IB_CHARGE_FULL_CONFIRM_MS - 1);
    CHECK(v.soc == 94 && v.charging);
    v = ib_charge_update(&c, true, 94, 4180, t0 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 100 && !v.charging);
    // 回差:电压回落到退出阈值以上仍保持已充满。
    v = ib_charge_update(&c, true, 94, IB_CHARGE_FULL_EXIT_MV, t0 + IB_CHARGE_FULL_CONFIRM_MS + MIN_MS);
    CHECK(v.soc == 100 && !v.charging);
    // 跌破退出阈值:清除判定,重新算充电中。
    v = ib_charge_update(&c, true, 94, IB_CHARGE_FULL_EXIT_MV - 1, t0 + IB_CHARGE_FULL_CONFIRM_MS + 2 * MIN_MS);
    CHECK(v.soc == 94 && v.charging);
    // 再次满足条件也要重新等满 10 分钟。
    int64_t t1 = t0 + IB_CHARGE_FULL_CONFIRM_MS + 3 * MIN_MS;
    v = ib_charge_update(&c, true, 94, 4180, t1);
    CHECK(v.charging);
    v = ib_charge_update(&c, true, 94, 4180, t1 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 100 && !v.charging);
}

// 确认期间电压掉下去:计时清零;SOC 低于下限不判充满;拔线后按电压退出已充满。
static void test_full_reset(void)
{
    ib_charge_t c;
    ib_charge_init(&c);
    ib_charge_update(&c, true, 95, 4160, 1000);
    ib_charge_update(&c, true, 95, 4140, 1000 + 5 * MIN_MS);     // 低于进入阈值
    ib_charge_view_t v = ib_charge_update(&c, true, 95, 4160, 1000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 95 && v.charging);

    // SOC 低于下限:电压再高也不判充满(保护电压读数异常)。
    ib_charge_init(&c);
    ib_charge_update(&c, true, IB_CHARGE_FULL_SOC_MIN - 1, 4200, 1000);
    v = ib_charge_update(&c, true, IB_CHARGE_FULL_SOC_MIN - 1, 4200, 1000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.charging);

    // 拔线(或 Mac 睡眠、SOF 停止)后电压仍高:继续显示 100、不充电;电压跌破退出阈值才回到实际读数。
    ib_charge_init(&c);
    ib_charge_update(&c, true, 94, 4180, 1000);
    v = ib_charge_update(&c, true, 94, 4180, 1000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 100);
    v = ib_charge_update(&c, false, 94, 4170, 2000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 100 && !v.charging);
    v = ib_charge_update(&c, false, 94, IB_CHARGE_FULL_EXIT_MV, 3000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 100 && !v.charging);
    v = ib_charge_update(&c, false, 93, IB_CHARGE_FULL_EXIT_MV - 1, 4000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 93 && !v.charging);
    // 判定已清除:插回 USB 重新算充电中,要再等满 10 分钟。
    v = ib_charge_update(&c, true, 94, 4180, 5000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 94 && v.charging);

    // 未充满时拔线:确认计时清零,插回后重新计时。
    ib_charge_init(&c);
    ib_charge_update(&c, true, 94, 4180, 1000);
    v = ib_charge_update(&c, false, 94, 4170, 1000 + 5 * MIN_MS);
    CHECK(v.soc == 94 && !v.charging);
    v = ib_charge_update(&c, true, 94, 4180, 1000 + 6 * MIN_MS);
    CHECK(v.charging);
    v = ib_charge_update(&c, true, 94, 4180, 1000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 94 && v.charging);
}

// 读数失败(-1)不改变判定:已充满保持,确认计时也不清零。
static void test_unknown_reading(void)
{
    ib_charge_t c;
    ib_charge_init(&c);
    ib_charge_update(&c, true, 94, 4180, 1000);
    ib_charge_view_t v = ib_charge_update(&c, true, -1, -1, 1000 + 5 * MIN_MS);
    CHECK(v.soc == -1 && !v.charging);
    v = ib_charge_update(&c, true, 94, -1, 1000 + 6 * MIN_MS);
    CHECK(v.soc == 94 && !v.charging);
    v = ib_charge_update(&c, true, 94, 4180, 1000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 100 && !v.charging);     // 计时从 1000 起算,没有被 -1 清零

    v = ib_charge_update(&c, true, -1, -1, 2000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == -1 && !v.charging);
    v = ib_charge_update(&c, true, 94, 4180, 3000 + IB_CHARGE_FULL_CONFIRM_MS);
    CHECK(v.soc == 100 && !v.charging);     // 已充满没有被 -1 清掉
}

int main(void)
{
    test_basic();
    test_full_confirm();
    test_full_reset();
    test_unknown_reading();
    TEST_DONE("test_ib_charge");
}
