// main/ib_crc32.h: 标准 CRC-32(IEEE 802.3,多项式 0xEDB88320),与 Mac 端 CRC32 一致。
#pragma once

#include <stddef.h>
#include <stdint.h>

// 可增量调用:首次传 0,之后把上一次返回值传回来。
uint32_t ib_crc32_update(uint32_t crc, const void *data, size_t len);
uint32_t ib_crc32(const void *data, size_t len);
