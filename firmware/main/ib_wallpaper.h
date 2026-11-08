// main/ib_wallpaper.h: 离线页自定义背景的分区读写。
//
// 分区布局:16 字节头("VKW1" + size + crc + 保留)+ 240×320 RGB565 像素。
// 头在最后写入;启动时 magic / 大小 / CRC 任一不符就回退固件内置猫图。
#pragma once

#include "esp_err.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// 找到 wallpaper 分区并只读映射;失败或内容无效时 available() 为 false。
esp_err_t ib_wallpaper_init(void);
bool ib_wallpaper_available(void);
// 有效时为映射到 flash 的 240×320 RGB565 首地址,否则 NULL。
const uint8_t *ib_wallpaper_pixels(void);

esp_err_t ib_wallpaper_begin(uint32_t size, uint32_t crc);
esp_err_t ib_wallpaper_write(uint32_t offset, const char *base64);
esp_err_t ib_wallpaper_finish(void);
esp_err_t ib_wallpaper_clear(void);
