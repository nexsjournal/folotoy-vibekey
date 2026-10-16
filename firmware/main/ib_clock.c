// main/ib_clock.c: 本地时间格式化。
#include "ib_clock.h"

#include <stdio.h>

static const char *const WEEKDAYS[7] = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" };

// 1970-01-01 起的天数 → 公历年月日(Howard Hinnant 的 civil_from_days 算法)。
static void days_to_civil(int64_t z, int *y, unsigned *m, unsigned *d)
{
    z += 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned mp = (5 * doy + 2) / 153;
    *d = doy - (153 * mp + 2) / 5 + 1;
    *m = mp < 10 ? mp + 3 : mp - 9;
    *y = (int)((int64_t)yoe + era * 400 + (*m <= 2));
}

void ib_clock_format(uint32_t local_epoch, char time_out[IB_CLOCK_TIME_LEN], char date_out[IB_CLOCK_DATE_LEN])
{
    uint32_t days = local_epoch / 86400U;
    uint32_t secs = local_epoch % 86400U;
    int year;
    unsigned month, day;
    days_to_civil((int64_t)days, &year, &month, &day);
    (void)year;
    unsigned weekday = (days + 4U) % 7U;   // 1970-01-01 是星期四
    snprintf(time_out, IB_CLOCK_TIME_LEN, "%02u:%02u", (unsigned)(secs / 3600U), (unsigned)(secs / 60U % 60U));
    snprintf(date_out, IB_CLOCK_DATE_LEN, "%s %02u/%02u", WEEKDAYS[weekday], month % 100U, day % 100U);
}
