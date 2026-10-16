// main/ib_ui.h: Passport 屏幕(LVGL 9)。只负责"显示什么、怎么动",不含协议与业务逻辑。
//
// 设计见 docs/device-ui.md。调用方(ib_app)决定当前页面与参数;本模块负责页面切换动画、
// 状态栏、按键反馈与各页面的逐帧动画。
//
// 线程:所有函数都可在任意非 LVGL 任务中调用,内部加 LVGL 锁;拿不到锁(> 1 s)时放弃本次更新并返回 false。
#pragma once

#include "esp_err.h"
#include "ib_icons.h"

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    IB_UI_OFFLINE = 0,      // Mac 未连接:时钟
    IB_UI_IDLE,             // 模式卡片
    IB_UI_REC,              // 录音
    IB_UI_PROC,             // 处理中
    IB_UI_DONE,             // 已输入
    IB_UI_ERR,              // 失败
    IB_UI_SUB,              // 字幕运行中
    IB_UI_LIST,             // 列表(Mac 驱动的应用切换器等)
    IB_UI_SCREEN_COUNT,
} ib_ui_screen_t;

typedef enum {
    IB_UI_MODE_DICT = 0,    // 听写
    IB_UI_MODE_TR,          // 翻译听写
    IB_UI_MODE_SUB,         // 字幕
    IB_UI_MODE_COUNT,
} ib_ui_mode_t;

typedef enum {
    IB_UI_KEY_UP = 0,
    IB_UI_KEY_DOWN,
    IB_UI_KEY_OK,
    IB_UI_KEY_COUNT,
} ib_ui_key_t;

typedef enum {
    IB_UI_AGENT_DONE = 0,   // Agent 完成:绿色对勾,15 s 后由 ib_app 关闭
    IB_UI_AGENT_INPUT,      // Agent 等你:暗橙色 "!",直到关闭
} ib_ui_agent_t;

// 列表页内容:最多 6 个可见行,选中项与滚动位置由 Mac 决定,设备只显示。
#define IB_UI_LIST_ROWS 6
typedef struct {
    char title[24];
    char items[IB_UI_LIST_ROWS][24];
    uint8_t rows;           // 可见行数 0..6
    uint16_t n;             // 列表总项数
    uint16_t top;           // items[0] 在完整列表里的序号
    uint16_t sel;           // 选中项的绝对序号
} ib_ui_list_t;

typedef enum {
    IB_UI_LINK_NONE = 0,
    IB_UI_LINK_USB,
    IB_UI_LINK_BLE,
} ib_ui_link_t;

// 建立全部页面与状态栏,初始显示 OFFLINE。需先 bsp_lvgl_init()。
esp_err_t ib_ui_init(void);

// 切换页面。screen 相同时只更新 mode/msg(IDLE 下模式变化会播放左右滑动动画)。
// msg:ASCII,最长 23 字节;DONE 为提示词(空则显示 TYPED),ERR 为原因,SUB 为应用名;
// IDLE 上为 "LIVE" 时表示 Mac 正在后台显示字幕,状态栏左侧显示 LIVE 徽章(代替链路文字)。
bool ib_ui_show(ib_ui_screen_t screen, ib_ui_mode_t mode, const char *msg);

// 音量电平 0..100,驱动 REC / SUB 动画(内部平滑)。
void ib_ui_set_level(uint8_t level);

// OK 键是否按住:REC 页据此提示 "RELEASE OK"(按住说话)或 "OK TO STOP"(切换模式)。
void ib_ui_set_ok_held(bool held);

// 状态栏:链路(online=false 时用暗色显示物理链路)、电量(soc<0 表示未知)。
void ib_ui_set_link(ib_ui_link_t link, bool online);
void ib_ui_set_battery(int soc, bool charging);

// OFFLINE 时钟:time 形如 "23:41",date 形如 "THU 10/15";time 为空串表示未知(显示 --:--)。
void ib_ui_set_clock(const char *time, const char *date);

// IDLE 页底部的引擎名(ASCII,最长 23 字节)。
void ib_ui_set_engine(const char *engine);

// 按键反馈:右侧对应按键提示闪白 150 ms(离线页无反馈)。
void ib_ui_key_press(ib_ui_key_t key);

// 右侧按键提示图标;IB_ICON_NONE 隐藏该键提示。
void ib_ui_set_key_icon(ib_ui_key_t key, ib_icon_t icon);

// 更新列表页内容(列表页可见时选中高亮平滑滑动到新位置)。
void ib_ui_set_list(const ib_ui_list_t *list);

// Agent 通知层:当前是 REC 页时只显示顶部 28 px 横幅(录音继续),否则全屏;
// 页面在 REC 与其它页之间切换时自动在横幅 / 全屏之间转换。source 为来源名(ASCII)。
void ib_ui_agent_show(ib_ui_agent_t kind, const char *source);
// 关闭通知层(200 ms 淡出)。未显示时无操作。
void ib_ui_agent_hide(void);

// 屏幕是否点亮。熄屏时暂停逐帧动画以省电,点亮时恢复。
void ib_ui_set_awake(bool awake);
