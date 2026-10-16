// main/ib_icons.h: 按键提示图标 id(纯逻辑,协议层与 UI 层共用,不依赖 ESP-IDF / LVGL)。
//
// keys 命令的值是图标 id(ASCII),固定集合见 icons/ib_icon_list.h(由 tools/gen-icon-font.sh 生成,
// 与图标字体同源,保证 id、枚举、字形一一对应)。空串或未知 id 都映射为 IB_ICON_NONE(设备隐藏该提示)。
#pragma once

typedef enum {
    IB_ICON_NONE = 0,
#define IB_ICON_DEF(name, id, glyph, codepoint) IB_ICON_##name,
#include "icons/ib_icon_list.h"
#undef IB_ICON_DEF
    IB_ICON_COUNT,
} ib_icon_t;

// 协议 id → 枚举;NULL、空串、未知 id 返回 IB_ICON_NONE(区分大小写)。
ib_icon_t ib_icon_from_id(const char *id);
// 枚举 → 协议 id;IB_ICON_NONE 返回 "",越界返回 "?"。
const char *ib_icon_id(ib_icon_t icon);
