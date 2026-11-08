#include "ib_crc32.h"

uint32_t ib_crc32_update(uint32_t crc, const void *data, size_t len)
{
    const uint8_t *p = data;
    crc = ~crc;
    for (size_t i = 0; i < len; i++) {
        crc ^= p[i];
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
        }
    }
    return ~crc;
}

uint32_t ib_crc32(const void *data, size_t len)
{
    return ib_crc32_update(0, data, len);
}
