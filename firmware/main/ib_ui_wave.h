// main/ib_ui_wave.h: 点阵声波(REC 与 SUB 页共用,docs/device-ui.md「声波」)。
//
// 声波画在点阵网格上(ib_ui_dots:25 列、8 px 节距、中心行 13),每列是一串竖排的 5x5 圆点,
// 垂直对称于中心行,列高 = 1 + 2 x 半高(半高 0..7 颗):
//   - "活柱"随当前电平起伏(每拍向目标靠近一半,跟手又不抖);
//   - 每 3 拍(约 100 ms)活柱存档成一根历史柱,历史柱整格跳向外侧并逐渐变暗;
//   - 静音时每列只剩中心行的一颗点,整行是一条点线——正好是 ib_dots_line,和其它页面的点阵无缝衔接。
// 两种排布:mirror(活柱在中央第 12 列,历史向左右两侧流出,REC 用,活柱红)和
// scroll(活柱在最右列,历史向左流,SUB 用,活柱白)。
//
// 节拍按时间推进(每 33 ms 一拍),掉帧时补齐,流动速度不变。全局只有一个共享实例(ib_wave_shared):
// REC / SUB 进入时 reset 它;离开声波页时 ib_dots 读它最后一帧做"按行塌缩成线"的衔接。只在 LVGL 任务里使用。
#pragma once

#include "ib_ui_gfx.h"

#include <stdbool.h>
#include <stdint.h>

#define IB_WAVE_MAX_COLS 24

typedef enum {
    IB_WAVE_MIRROR,
    IB_WAVE_SCROLL,
} ib_wave_layout_t;

typedef struct {
    int16_t col[IB_WAVE_MAX_COLS];  // 历史柱半高(颗,x16 定点),col[0] 最新
    int32_t live;                   // 活柱半高(x16)
    int32_t intro;                  // 柱高系数 0..IB_P_ONE(进入时长出、离开时塌缩)
    uint32_t t0;                    // 起点时刻(ms)
    uint32_t ticks;                 // 已推进的拍数
    uint8_t cols;                   // 历史柱数:mirror 每侧 12,scroll 24
    ib_wave_layout_t layout;
    uint8_t live_color;             // ib_dot_color_t
    int32_t far;                    // 最远端历史柱的灰度
} ib_wave_t;

ib_wave_t *ib_wave_shared(void);
// 清空并从 now_ms 开始计拍。
void ib_wave_reset(ib_wave_t *w, ib_wave_layout_t layout, uint32_t now_ms);
// 推进到 now_ms:level 为 0..1000 的电平,intro 为 0..IB_P_ONE 的长出进度。
void ib_wave_step(ib_wave_t *w, int32_t level, int32_t intro, uint32_t now_ms);
// 在点阵控件(IB_DOTS_BOX_*)里画当前帧。
void ib_wave_draw(const ib_fx_t *fx, const ib_wave_t *w);
