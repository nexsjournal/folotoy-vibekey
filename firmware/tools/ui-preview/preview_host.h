// tools/ui-preview/preview_host.h: 主机预览环境:虚拟 240x320 RGB565 显示、可控的时钟、PNG 导出。
//
// 显示与真机一样用 LVGL 的 PARTIAL 渲染模式和 20 行双缓冲(bsp_display_lvgl.c),flush 回调把每块
// 拷进一张完整的帧缓冲;导出时把 RGB565 转成 RGB888 并按整数倍放大(最近邻,像素保持清晰)。
// 时间完全由预览程序推进:preview_advance() 以 5 ms 步长推进 lv_tick 并调用 lv_timer_handler,
// 与 esp_lvgl_port 的 5 ms 定时器节拍一致,因此动画在第 N 毫秒的画面与真机相同。
#pragma once

#include <stdbool.h>
#include <stdint.h>

#define PREVIEW_W     240
#define PREVIEW_H     320

// 初始化 LVGL 与虚拟显示。必须在 ib_ui_init() 之前调用。
void preview_init(void);
// 推进 ms 毫秒(5 ms 一步,每步运行 LVGL 定时器,包括刷新与动画)。
void preview_advance(uint32_t ms);
// 当前虚拟时间(ms)。
uint32_t preview_now(void);
// 立即刷新屏幕并把帧缓冲按 scale 倍写成 PNG。成功返回 true。
bool preview_capture(const char *path, int scale);
// LVGL 内存池峰值使用(字节),用于粗略观察内存占用。
uint32_t preview_mem_max_used(void);
