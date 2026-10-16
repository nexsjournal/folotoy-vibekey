// main/ib_link.h: 链路编号,各模块共用的唯一定义(USB 优先于 BLE)。
#pragma once

typedef enum {
    IB_LINK_USB = 0,
    IB_LINK_BLE,
    IB_LINK_COUNT,
} ib_link_t;
