// main/ib_ui_dots.h: 点阵——设备界面唯一的主视觉图元(docs/device-ui.md「点阵」)。
//
// 整个界面的主体都由同一种 5x5 圆点组成,排在 8 px 网格上:25 列 x 若干行,列 c 的点心 x = IB_UI_CX - 96 + 8c
// (c = 12 落在内容区居中线),行 r 的点心 y(屏幕)= 28 + 8r,声波中心行 r = 13(屏幕 y 132)。
// 模式图标(mic / 对话气泡 / CC)、对勾、叉、一条线、声波都是这批点;页面之间切换时点"重排"(morph):
// 每颗点从旧图案的位置飞到新图案的位置,从左到右按列错峰,听写全过程是一段连续的粒子动画。
//
// 本模块持有唯一的"当前图案"与转场状态(各页共用,ib_ui.c 直切时新页接着旧页的最后一帧画):
//   ib_dots_show(target, ...)  开始一次转场(或直接显示);from_wave 时先把声波按行塌缩成一条线再重排
//   ib_dots_draw(fx, now)      在页面的点阵控件里画当前帧(控件统一为 IB_DOTS_BOX_*,见下)
// 只在 LVGL 任务里使用。
#pragma once

#include "ib_ui_gfx.h"
#include "ib_ui_page.h"

#include <stdbool.h>
#include <stdint.h>

#define IB_DOTS_COLS     25
#define IB_DOTS_PITCH    8
#define IB_DOTS_ROW_MID  13                 // 声波 / 线所在的行
#define IB_DOTS_MAX      64                 // 一个图案最多 64 颗点
// 每页的点阵控件:内容区全宽,屏幕 y 60..204(行 4..21),页面坐标 y = 36。
#define IB_DOTS_BOX_Y    (60 - IB_UI_BAR_H)
#define IB_DOTS_BOX_H    144

// 点的颜色(索引,绘制时换成 RGB565 友好的颜色)。
typedef enum {
    IB_DOT_WHITE,       // #F0F0F0
    IB_DOT_SOFT,        // #C8C8C8(IDLE 字形底色,扫描光经过时变白)
    IB_DOT_GRAY,        // #505050
    IB_DOT_DIM,         // #303030
    IB_DOT_REC,         // 录音红
    IB_DOT_DONE,        // 完成绿
    IB_DOT_ERR,         // 失败红
} ib_dot_color_t;

typedef struct {
    int8_t c, r;        // 网格坐标
    uint8_t color;      // ib_dot_color_t
} ib_dot_t;

typedef struct {
    ib_dot_t d[IB_DOTS_MAX];
    uint8_t n;
} ib_dots_t;

typedef enum {
    IB_DOTS_MIC,        // 听写
    IB_DOTS_TR,         // 翻译听写:两个对话气泡
    IB_DOTS_CC,         // 字幕
    IB_DOTS_CHECK,
    IB_DOTS_X,
    IB_DOTS_BANG,       // 感叹号(Agent 等待输入)
    IB_DOTS_GLYPH_COUNT,
} ib_dots_glyph_t;

// 网格坐标 → 点阵控件内的像素坐标(点心)。
int32_t ib_dots_x(int32_t c);
int32_t ib_dots_y(int32_t r);
lv_color_t ib_dots_color(uint8_t color);

void ib_dots_glyph(ib_dots_t *out, ib_dots_glyph_t glyph, uint8_t color);
// 第 IB_DOTS_ROW_MID 行的 25 颗点;中间那颗用 center 色。
void ib_dots_line(ib_dots_t *out, uint8_t color, uint8_t center);

// 页面 enter 时调用:直切而来(ctx->prev_screen 有效)时从上一页的最后一帧重排过来,上一页是声波页(REC / SUB)
// 时先塌缩;普通淡入淡出切换时直接显示。
void ib_dots_enter(const ib_ui_ctx_t *ctx, const ib_dots_t *target);
// 开始显示 target:animate 为 false 时立即显示;为 true 时从当前图案重排过去(≤ 320 ms)。
// from_wave 为 true 时先用 120 ms 把共享声波(ib_wave_shared)按行塌缩成线,再从线重排。
void ib_dots_show(const ib_dots_t *target, bool animate, bool from_wave, uint32_t now_ms);
// 转场是否已经结束(页面可以接管画声波、扫描等自己的内容)。
bool ib_dots_settled(uint32_t now_ms);
// 转场结束的时刻。
uint32_t ib_dots_settle_ms(void);
// 画当前帧(转场中或静止的图案)。dx 为整体水平偏移(ERR 抖动)。
void ib_dots_draw(const ib_fx_t *fx, uint32_t now_ms, int32_t dx);
// 当前(目标)图案,页面可以在静止时自己按它画(例如 IDLE 的扫描光、DONE 的变色)。
const ib_dots_t *ib_dots_current(void);
// 画一颗点:半径 2.5(5x5,圆角 2);grow 为额外的放大像素。
void ib_dots_dot(const ib_fx_t *fx, int32_t x, int32_t y, lv_color_t c, int32_t grow);
