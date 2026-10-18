// main/ib_ui_hints.h: 右侧竖排按键提示列(UI 内部模块)。
//
// Passport 的三个键在机身右侧,自上而下为 上 / 下 / OK(电源键在左侧靠上)。每个键的提示是一个图标
// (Material Icons Round,22 px,见 icons/),贴着屏幕右边缘、与对应实体键水平对齐,图标右侧有一个指向
// 机身边缘的小 ">"。图标由 Mac 的 keys 命令选择;IB_ICON_NONE 隐藏该键提示。按下时图标与箭头闪白 150 ms。
// 离线页不显示。所有函数运行在 LVGL 任务或持有 LVGL 锁的任务里。
#pragma once

#include "ib_icons.h"
#include "ib_ui.h"
#include "lvgl.h"

#include <stdbool.h>
#include <stdint.h>

// ★ 三个实体键在屏幕上对应的纵坐标(屏幕坐标,图标的垂直中心)。换机身或实测有偏差时只改这里。
#define IB_HINT_Y_UP    70
#define IB_HINT_Y_DOWN  170
#define IB_HINT_Y_OK    270
// 提示列占用的右侧宽度;页面内容只使用左边 IB_UI_W - IB_HINT_COL_W 的区域,不会与提示重叠。
#define IB_HINT_COL_W   22

void ib_hints_create(lv_obj_t *screen);
void ib_hints_set_icon(ib_ui_key_t key, ib_icon_t icon);
// 按键反馈:可用时图标与标记点亮起;禁用时(见 ib_hints_set_disabled)改为"不可用"反馈:
// 标记点闪红并左右抖动,图标保持暗色。
void ib_hints_press(ib_ui_key_t key);
void ib_hints_set_visible(bool visible);
// 禁用整列提示(PROC 页:上一句还在处理,OK 等键暂时不可用):图标与标记画成更暗的禁用色。
void ib_hints_set_disabled(bool disabled);
