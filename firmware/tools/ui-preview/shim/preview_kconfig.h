// tools/ui-preview/shim/preview_kconfig.h: 主机预览的 LVGL 配置。
//
// 直接沿用固件编译生成的 sdkconfig.h(firmware/build/config/),保证颜色深度、字体、渐变、
// 刷新周期等与真机完全一致;只覆盖少数主机才需要的项。由 CMake 通过
// LV_CONF_KCONFIG_EXTERNAL_INCLUDE 注入 LVGL。
#pragma once

#include "sdkconfig.h"

// 64 位主机上指针翻倍,LVGL 对象比 ESP32-C3 上大,内存池放宽到 256 KB(真机是 40 KB)。
// 预览结束时打印的内存峰值仅供参考,不能直接等同于真机。
#undef CONFIG_LV_MEM_SIZE_KILOBYTES
#define CONFIG_LV_MEM_SIZE_KILOBYTES 256

// 主机上打开 LVGL 警告日志,断言失败直接中止(真机是死循环)。
#define CONFIG_LV_USE_LOG 1
#define CONFIG_LV_LOG_PRINTF 1
#define CONFIG_LV_LOG_LEVEL 2           // LV_LOG_LEVEL_WARN
#undef CONFIG_LV_ASSERT_HANDLER
#define CONFIG_LV_ASSERT_HANDLER __builtin_trap();
