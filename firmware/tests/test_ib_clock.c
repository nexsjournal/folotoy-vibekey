// tests/test_ib_clock.c: ib_clock 主机测试。
#include "ib_clock.h"
#include "test_common.h"

static void check(uint32_t t, const char *time, const char *date)
{
    char tb[IB_CLOCK_TIME_LEN];
    char db[IB_CLOCK_DATE_LEN];
    ib_clock_format(t, tb, db);
    CHECK_STR(tb, time);
    CHECK_STR(db, date);
}

int main(void)
{
    check(0, "00:00", "THU 01/01");
    check(951782400, "00:00", "TUE 02/29");         // 闰日
    check(1789097696, "03:34", "FRI 09/11");        // 协议文档里的示例值
    check(1792107660, "23:41", "THU 10/15");
    check(4102444799U, "23:59", "THU 12/31");
    check(4294967295U, "06:28", "SUN 02/07");       // uint32 上限
    TEST_DONE("test_ib_clock");
}
