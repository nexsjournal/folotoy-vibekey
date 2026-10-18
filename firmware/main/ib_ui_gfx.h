// main/ib_ui_gfx.h: UI 内部绘图工具:配色、缓动、整数三角函数、自绘控件与 lv_draw_* 的简化封装。
//
// 只被 ib_ui*.c 使用。所有函数都运行在 LVGL 任务(或持有 LVGL 锁的任务)里。
// 动画大量使用"自绘控件":一个没有样式的 lv_obj,在 LV_EVENT_DRAW_MAIN 里用 lv_draw_* 画图元,
// 每个页面只需要少量 LVGL 对象,内存占用小;每帧只重绘这些控件所在的区域。
#pragma once

#include "ib_ui.h"
#include "lvgl.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// ---- 配色(docs/device-ui.md):单色克制风格 ----
// 所有模式都用白 / 灰,不用颜色区分模式。
// 彩色只用于少数语义:录音红(REC 活柱、状态栏红点、低电量)、完成绿(DONE)、失败红(ERR)、Agent 等待输入橙。
//
// ★ 灰色必须是 RGB565 精确值:R、G、B 相等且为 8 的倍数(转成 565 后 G6 = 2 x R5,三通道亮度一致)。
//   否则 R/B 只有 5 位、G 有 6 位,舍入不同会让灰色偏绿。同理,黑底上的"低透明度白色"经混合后
//   三通道各自舍入也会偏绿,所以光晕、底色一律用 ib_gray() 画不透明的精确灰,而不是白色 + 透明度。
//   彩色的 R、B 取 8 的倍数、G 取 4 的倍数,真机与预览一致。
#define IB_COLOR_BG        0x000000
#define IB_COLOR_HAIR      0x101010     // 最暗的晕、发丝线
#define IB_COLOR_SURFACE   0x181818     // 轨道、横幅底
#define IB_COLOR_MUTE      0x303030     // 未激活分页点、按键边缘标记(静止)、声波最远端
#define IB_COLOR_RING      0x505050     // IDLE 细圈、三级文字(引擎名、waiting for Mac)
#define IB_COLOR_TEXT_DIM  0x686868     // 次要文字、按键提示图标(静止)
#define IB_COLOR_TEXT_MID  0xA0A0A0     // 状态栏文字、亮弧
#define IB_COLOR_TEXT      0xF0F0F0     // 主文字与主图形
#define IB_COLOR_REC       0xF83858
#define IB_COLOR_DONE      0x28E498
#define IB_COLOR_ERR       0xF85858
#define IB_COLOR_AGENT     0xC88848     // 暗橙,只用于 Agent "input" 通知

#define IB_C(hex) lv_color_hex(hex)

// RGB565 精确灰:v 为 0..255 的亮度,向下取到 8 的倍数。
lv_color_t ib_gray(int32_t v);
// 在两个精确灰之间插值(p 为 0..IB_P_ONE),结果仍是精确灰。
lv_color_t ib_gray_lerp(uint32_t from_hex, uint32_t to_hex, int32_t p);

// ---- 图标字体(tools/gen-icon-font.sh 生成,Material Icons Round)----
LV_FONT_DECLARE(ib_icon_font_12);      // 右侧按键提示(12 px)
LV_FONT_DECLARE(ib_icon_font_56);      // 页面主图标
typedef enum {
#define IB_ICON_LARGE_DEF(name, glyph, codepoint) IB_GLYPH_##name,
#include "icons/ib_icon_large_list.h"
#undef IB_ICON_LARGE_DEF
    IB_GLYPH_COUNT,
} ib_glyph_t;
// 56 px 主图标的 UTF-8 字形(配合 ib_icon_font_56 使用);越界返回 ""。
const char *ib_glyph(ib_glyph_t glyph);
// 按键提示图标(keys 命令的 id)的 UTF-8 字形(配合 ib_icon_font_12 使用);IB_ICON_NONE 或越界返回 ""。
const char *ib_icon_glyph(ib_icon_t icon);

// ---- 缓动:输入输出都是 0..1024 的定点进度 ----
#define IB_P_ONE 1024
int32_t ib_ease_out_cubic(int32_t p);
int32_t ib_ease_in_out_sine(int32_t p);
int32_t ib_ease_in_out_cubic(int32_t p);
// 把 [t0, t0+dur) 映射到 0..IB_P_ONE(之前为 0,之后为 IB_P_ONE)。
int32_t ib_progress(uint32_t t, uint32_t t0, uint32_t dur);
// 周期为 period_ms 的平滑呼吸波,返回 0..IB_P_ONE。
int32_t ib_breath(uint32_t now_ms, uint32_t period_ms);
// 整数正弦/余弦:角度单位 0.1 度,返回 -32768..32768。
int32_t ib_sin10(int32_t deci_deg);
int32_t ib_cos10(int32_t deci_deg);
// 线性插值 a + (b - a) * p / IB_P_ONE。
int32_t ib_lerp(int32_t a, int32_t b, int32_t p);
// 透明度乘法:opa * p / IB_P_ONE,结果限制在 0..255。
lv_opa_t ib_opa_scale(int32_t opa, int32_t p);

// ---- 对象工具 ----
// 创建一个无样式、不可点击、不可滚动的透明容器。
lv_obj_t *ib_box_create(lv_obj_t *parent, int32_t x, int32_t y, int32_t w, int32_t h);
// 创建自绘控件:draw_cb 在 LV_EVENT_DRAW_MAIN 时调用,user 通过 lv_event_get_user_data 取回。
lv_obj_t *ib_fx_create(lv_obj_t *parent, int32_t x, int32_t y, int32_t w, int32_t h, lv_event_cb_t draw_cb, void *user);
// 创建文本标签:宽 w、水平居中,纵向位置 y(父对象内坐标)。
lv_obj_t *ib_label_create(lv_obj_t *parent, const lv_font_t *font, uint32_t color, int32_t y, int32_t w);
// 让单行文字的垂直中心落在 cy:返回 ib_label_create 需要的顶部 y。
int32_t ib_font_top(const lv_font_t *font, int32_t cy);
// 小标签(Montserrat 12,大写,加字距):状态栏、THINKING、TRANSLATE、列表标题、操作提示等。
lv_obj_t *ib_caption_create(lv_obj_t *parent, uint32_t color, int32_t y, int32_t w, int32_t letter_space);

// ---- 自绘上下文:draw_cb 开头调用 ib_fx_begin,之后的坐标都相对控件左上角 ----
typedef struct {
    lv_layer_t *layer;
    int32_t ox, oy;         // 控件左上角屏幕坐标
    int32_t w, h;
    lv_opa_t opa;           // 控件及其所有父对象的 opa 乘积(页面淡入淡出)
} ib_fx_t;

void ib_fx_begin(ib_fx_t *fx, lv_event_t *e);
void ib_fx_circle(const ib_fx_t *fx, int32_t cx, int32_t cy, int32_t r, lv_color_t c, lv_opa_t opa);
// 平头弧:多段弧首尾相接(如 PROC 彗星尾)时用,圆头会在接缝处鼓包。
void ib_fx_arc_flat(const ib_fx_t *fx, int32_t cx, int32_t cy, int32_t r, int32_t width, int32_t start, int32_t end,
                    lv_color_t c, lv_opa_t opa);
void ib_fx_ring(const ib_fx_t *fx, int32_t cx, int32_t cy, int32_t r, int32_t width, lv_color_t c, lv_opa_t opa);
// 弧:角度单位度,0 度为 3 点钟方向、顺时针。不足一整圈时两端为圆头。
void ib_fx_arc(const ib_fx_t *fx, int32_t cx, int32_t cy, int32_t r, int32_t width, int32_t start, int32_t end,
               lv_color_t c, lv_opa_t opa);
void ib_fx_line(const ib_fx_t *fx, int32_t x1, int32_t y1, int32_t x2, int32_t y2, int32_t width, lv_color_t c,
                lv_opa_t opa);
void ib_fx_rect(const ib_fx_t *fx, int32_t x, int32_t y, int32_t w, int32_t h, int32_t radius, lv_color_t c,
                lv_opa_t opa);
// 竖直渐变矩形:顶部 top、底部 bottom。
void ib_fx_rect_vgrad(const ib_fx_t *fx, int32_t x, int32_t y, int32_t w, int32_t h, int32_t radius,
                      lv_color_t top, lv_color_t bottom, lv_opa_t opa);
void ib_fx_frame(const ib_fx_t *fx, int32_t x, int32_t y, int32_t w, int32_t h, int32_t radius, int32_t border,
                 lv_color_t c, lv_opa_t opa);
// 从 (x, cy) 起左对齐绘制单行文本(不折行);超长时调用方先用 ib_text_fit() 截断。
void ib_fx_text_left(const ib_fx_t *fx, int32_t x, int32_t cy, const char *text, const lv_font_t *font,
                     lv_color_t c, lv_opa_t opa);
// 把 ASCII 文本复制到 out(容量 cap),宽度超过 max_w 像素时截断并加 ".."。
void ib_text_fit(const char *text, const lv_font_t *font, int32_t max_w, char *out, size_t cap);
// 以 (cx, cy) 为中心绘制文本。text 必须在本次渲染结束前保持有效(静态字符串或 UI 上下文里的缓冲)。
void ib_fx_text(const ib_fx_t *fx, int32_t cx, int32_t cy, const char *text, const lv_font_t *font, lv_color_t c,
                lv_opa_t opa);
