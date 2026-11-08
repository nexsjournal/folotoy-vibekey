// main/ib_base64.h: wallpaper 分块传输用的标准 Base64 解码(纯 C,可主机测试)。
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// 解码到 out(cap 字节)。成功返回字节数;非法字符、长度不是 4 的倍数或放不下时返回 -1。
int ib_base64_decode(const char *in, size_t len, uint8_t *out, size_t cap);
