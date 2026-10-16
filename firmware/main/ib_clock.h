// main/ib_clock.h: 把 Mac 下发的本地时间格式化成离线时钟页的时间与日期。
// 纯 C,不依赖 ESP-IDF,由 tests/test_ib_clock.c 在主机上测试。
#pragma once

#include <stdint.h>

#define IB_CLOCK_TIME_LEN 6     // "HH:MM" + NUL
#define IB_CLOCK_DATE_LEN 10    // "THU 10/15" + NUL

// local_epoch 为已加时区偏移的 Unix 秒(不再做时区换算)。
void ib_clock_format(uint32_t local_epoch, char time_out[IB_CLOCK_TIME_LEN], char date_out[IB_CLOCK_DATE_LEN]);
