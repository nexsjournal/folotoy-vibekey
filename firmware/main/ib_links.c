// main/ib_links.c: 链路在线状态实现(见 ib_links.h)。
#include "ib_links.h"

void ib_links_init(ib_links_t *l)
{
    for (int i = 0; i < IB_LINK_COUNT; i++) l->seen_ms[i] = 0;
    l->usb_present = false;
    l->usb_absent_since = 0;
}

void ib_links_seen(ib_links_t *l, ib_link_t link, int64_t now_ms)
{
    if ((unsigned)link < IB_LINK_COUNT) l->seen_ms[link] = now_ms > 0 ? now_ms : 1;
}

void ib_links_drop(ib_links_t *l, ib_link_t link)
{
    if ((unsigned)link < IB_LINK_COUNT) l->seen_ms[link] = 0;
}

bool ib_links_alive(const ib_links_t *l, ib_link_t link, int64_t now_ms)
{
    if ((unsigned)link >= IB_LINK_COUNT || l->seen_ms[link] == 0) return false;
    return now_ms - l->seen_ms[link] < IB_LINK_TIMEOUT_MS;
}

bool ib_links_any(const ib_links_t *l, int64_t now_ms)
{
    return ib_links_alive(l, IB_LINK_USB, now_ms) || ib_links_alive(l, IB_LINK_BLE, now_ms);
}

ib_link_t ib_links_preferred(const ib_links_t *l, int64_t now_ms)
{
    if (ib_links_alive(l, IB_LINK_USB, now_ms)) return IB_LINK_USB;
    if (ib_links_alive(l, IB_LINK_BLE, now_ms)) return IB_LINK_BLE;
    return IB_LINK_COUNT;
}

bool ib_links_usb_present(ib_links_t *l, bool raw_present, int64_t now_ms)
{
    if (raw_present) {
        // 上升沿不去抖:插线后马上显示 USB 图标与充电状态。
        l->usb_present = true;
        l->usb_absent_since = 0;
        return true;
    }
    if (!l->usb_present) return false;
    if (l->usb_absent_since == 0) l->usb_absent_since = now_ms > 0 ? now_ms : 1;
    // 计时起点取"首次读到不在位"与"最近一条 USB 命令"中较晚者:命令能到达说明主机仍在。
    int64_t evidence = l->usb_absent_since;
    if (l->seen_ms[IB_LINK_USB] > evidence) evidence = l->seen_ms[IB_LINK_USB];
    if (now_ms - evidence < IB_USB_ABSENT_CONFIRM_MS) return true;
    l->usb_present = false;
    l->usb_absent_since = 0;
    return false;
}
