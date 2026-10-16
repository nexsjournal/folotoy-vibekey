// tools/ui-preview/preview_host.c: 主机预览环境实现(见 preview_host.h)。
#include "preview_host.h"

#include "bsp_display.h"
#include "lvgl.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBIW_ASSERT(x) ((void)0)
#include "stb_image_write.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TICK_STEP_MS  5
#define BUF_LINES     20            // 与固件 bsp_display_lvgl.c 相同

static uint32_t s_tick;
static uint16_t s_fb[PREVIEW_H][PREVIEW_W];             // RGB565
static uint16_t s_buf1[PREVIEW_W * BUF_LINES];
static uint16_t s_buf2[PREVIEW_W * BUF_LINES];
static lv_display_t *s_disp;

// ---- 固件 BSP 接口的主机替身:单线程,锁总是成功 ----
bool bsp_lvgl_lock(int timeout_ms)
{
    (void)timeout_ms;
    return true;
}

void bsp_lvgl_unlock(void)
{
}

static uint32_t tick_cb(void)
{
    return s_tick;
}

static void flush_cb(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    const uint16_t *src = (const uint16_t *)px_map;
    int32_t w = lv_area_get_width(area);
    for (int32_t y = area->y1; y <= area->y2; y++) {
        if (y < 0 || y >= PREVIEW_H) {
            src += w;
            continue;
        }
        for (int32_t x = area->x1; x <= area->x2; x++, src++) {
            if (x >= 0 && x < PREVIEW_W) s_fb[y][x] = *src;
        }
    }
    lv_display_flush_ready(disp);
}

void preview_init(void)
{
    lv_init();
    lv_tick_set_cb(tick_cb);
    s_disp = lv_display_create(PREVIEW_W, PREVIEW_H);
    lv_display_set_color_format(s_disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(s_disp, s_buf1, s_buf2, sizeof(s_buf1), LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(s_disp, flush_cb);
}

void preview_advance(uint32_t ms)
{
    for (uint32_t t = 0; t < ms; t += TICK_STEP_MS) {
        s_tick += TICK_STEP_MS;
        lv_timer_handler();
    }
}

uint32_t preview_now(void)
{
    return s_tick;
}

bool preview_capture(const char *path, int scale)
{
    lv_refr_now(s_disp);
    int w = PREVIEW_W * scale, h = PREVIEW_H * scale;
    uint8_t *rgb = malloc((size_t)w * h * 3);
    if (!rgb) return false;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint16_t p = s_fb[y / scale][x / scale];
            uint8_t r = (uint8_t)((p >> 11) & 0x1F), g = (uint8_t)((p >> 5) & 0x3F), b = (uint8_t)(p & 0x1F);
            uint8_t *o = rgb + ((size_t)y * w + x) * 3;
            // 5/6 位扩展到 8 位时复制高位,纯白得到 255 而不是 248。
            o[0] = (uint8_t)((r << 3) | (r >> 2));
            o[1] = (uint8_t)((g << 2) | (g >> 4));
            o[2] = (uint8_t)((b << 3) | (b >> 2));
        }
    }
    int ok = stbi_write_png(path, w, h, 3, rgb, w * 3);
    free(rgb);
    return ok != 0;
}

uint32_t preview_mem_max_used(void)
{
    lv_mem_monitor_t mon;
    lv_mem_monitor(&mon);
    return (uint32_t)mon.max_used;
}
