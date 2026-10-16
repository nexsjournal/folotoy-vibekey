// main/ib_ui_agent.h: Agent 通知层(UI 内部模块),位于所有页面、状态栏与右侧按键提示列之上。
//
// 全屏模式:done = 绿色对勾从小放大回弹 + 两圈光环向外扩散 + 标题 "DONE";
//           input = 暗橙色 "!" 左右轻摇 + 光环持续呼吸 + 标题 "YOUR TURN";下方来源名。
// 横幅模式(录音中):顶部状态栏下方 28 px 横幅(图标 + 来源名,过长显示省略号),只占左侧内容区,
// 不遮挡录音动画主体与右侧按键提示列。
// 全屏出现:黑色背景 100 ms 铺满后内容再 160 ms 淡入;关闭:内容 120 ms 淡出后背景再 100 ms 撤掉;
// 任何时刻通知内容都不会与下面的页面内容叠在一起。横幅整体 200 ms 淡入 / 淡出。所有函数运行在 LVGL 任务或持有 LVGL 锁的任务里。
#pragma once

#include "ib_ui.h"
#include "lvgl.h"

#include <stdbool.h>
#include <stdint.h>

void ib_agent_create(lv_obj_t *screen);
void ib_agent_show(ib_ui_agent_t kind, const char *source, bool banner, uint32_t now_ms);
void ib_agent_set_banner(bool banner, uint32_t now_ms);
void ib_agent_hide(void);
// 逐帧动画。
void ib_agent_frame(uint32_t now_ms);
// 是否正以全屏不透明方式盖住下面的页面(此时页面不必逐帧重绘)。
bool ib_agent_covering(void);
