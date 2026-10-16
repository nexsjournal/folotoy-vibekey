// tools/ui-preview/shim/bsp_display.h: 主机替身。预览是单线程,LVGL 锁总是立即成功。
// 只声明固件 UI 代码(ib_ui*.c)实际用到的接口。
#pragma once

#include <stdbool.h>

bool bsp_lvgl_lock(int timeout_ms);
void bsp_lvgl_unlock(void);
