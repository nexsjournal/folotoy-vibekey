// main/ib_ui_page.h: UI 内部的页面接口。每个页面一个 .c 文件,ib_ui.c 只通过这里的接口调度它们。
//
// 页面生命周期(都运行在 LVGL 任务或持有 LVGL 锁的任务里):
//   create  建立页面控件(一次),返回页面根容器(240 x 296,位于状态栏下方)
//   enter   页面变为可见:重置动画起点
//   update  页面可见期间 mode / msg 变化
//   frame   约 30 fps 的逐帧回调:推进动画状态并 invalidate 需要重绘的自绘控件
#pragma once

#include "ib_ui.h"
#include "ib_ui_hints.h"
#include "lvgl.h"

#include <stdbool.h>
#include <stdint.h>

#define IB_UI_W        240
#define IB_UI_H        320
#define IB_UI_BAR_H    24
#define IB_UI_PAGE_H   (IB_UI_H - IB_UI_BAR_H)
// 在线页面只使用左侧内容区,右侧留给按键提示列;内容在内容区内水平居中。
#define IB_UI_CONTENT_W (IB_UI_W - IB_HINT_COL_W)
#define IB_UI_CX        (IB_UI_CONTENT_W / 2)
#define IB_UI_TEXT_MAX 24

// 页面共享的显示上下文,由 ib_ui.c 维护。
typedef struct {
    ib_ui_mode_t mode;
    char msg[IB_UI_TEXT_MAX];
    char engine[IB_UI_TEXT_MAX];
    char time[8];
    char date[12];
    uint8_t level;          // Mac 下发的原始电平 0..100
    int32_t level_smooth;   // 平滑后的电平,0..1000(每帧向目标靠近 35%)
    bool ok_held;
    uint32_t enter_ms;      // 当前页面进入时刻(lv_tick)
    uint32_t now_ms;        // 本帧时刻
    ib_ui_list_t list;      // 列表页内容
} ib_ui_ctx_t;

typedef struct {
    lv_obj_t *(*create)(lv_obj_t *parent, const ib_ui_ctx_t *ctx);
    void (*enter)(const ib_ui_ctx_t *ctx);
    void (*update)(const ib_ui_ctx_t *ctx);
    void (*frame)(const ib_ui_ctx_t *ctx);
} ib_ui_page_t;

extern const ib_ui_page_t ib_ui_page_offline;
extern const ib_ui_page_t ib_ui_page_idle;
extern const ib_ui_page_t ib_ui_page_rec;
extern const ib_ui_page_t ib_ui_page_proc;
extern const ib_ui_page_t ib_ui_page_done;
extern const ib_ui_page_t ib_ui_page_err;
extern const ib_ui_page_t ib_ui_page_sub;
extern const ib_ui_page_t ib_ui_page_list;

