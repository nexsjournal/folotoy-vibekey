// tests/test_ib_keys.c: ib_keys(按键过滤)与 ib_links(链路在线、USB 在位去抖)主机测试。
#include "ib_keys.h"
#include "ib_links.h"
#include "test_common.h"

// 测试时钟:每个事件默认间隔 200 ms(远离回弹锁定窗口),回弹用例显式设置时刻。
static int64_t s_now = 1000;

static ib_key_action_t H(ib_keys_t *k, ib_key_t key, ib_key_ev_t ev, bool online, bool dark, bool agent)
{
    s_now += 200;
    return ib_keys_handle(k, key, ev, s_now, online, dark, agent);
}

static ib_key_action_t at(ib_keys_t *k, int64_t t, ib_key_t key, ib_key_ev_t ev)
{
    s_now = t;
    return ib_keys_handle(k, key, ev, t, true, false, false);
}

static void test_bounce(void)
{
    ib_keys_t k;
    ib_keys_reset(&k);
    ib_key_action_t a;
    int downs = 0, ups = 0;

    // 一次真实按压后,松开回弹在 60 ms 内又报了一对 down/up:只上报第一对。
    a = at(&k, 10000, IB_KEY_OK, IB_KEY_EV_DOWN); downs += a.send;
    a = at(&k, 10150, IB_KEY_OK, IB_KEY_EV_UP);   ups += a.send;
    a = at(&k, 10175, IB_KEY_OK, IB_KEY_EV_DOWN); downs += a.send;   // 回弹
    a = at(&k, 10200, IB_KEY_OK, IB_KEY_EV_UP);   ups += a.send;     // 回弹的松开
    a = at(&k, 10250, IB_KEY_OK, IB_KEY_EV_DOWN); downs += a.send;   // 距上次松开 50 ms,仍是回弹
    a = at(&k, 10270, IB_KEY_OK, IB_KEY_EV_LONG);
    CHECK(!a.send);
    a = at(&k, 10280, IB_KEY_OK, IB_KEY_EV_UP);   ups += a.send;
    CHECK(downs == 1 && ups == 1);

    // 锁定只针对同一个键:松开 OK 后立刻按 UP 正常上报。
    a = at(&k, 10290, IB_KEY_UP, IB_KEY_EV_DOWN);
    CHECK(a.send);
    a = at(&k, 10400, IB_KEY_UP, IB_KEY_EV_UP);
    CHECK(a.send);

    // 窗口过后(>= 60 ms)的再次按下是真实按键。
    a = at(&k, 10280 + IB_KEYS_REPRESS_LOCKOUT_MS, IB_KEY_OK, IB_KEY_EV_DOWN);
    CHECK(a.send);
    a = at(&k, 10500, IB_KEY_OK, IB_KEY_EV_UP);
    CHECK(a.send);

    // 快速连按(间隔 120 ms)全部保留。
    downs = ups = 0;
    for (int i = 0; i < 5; i++) {
        int64_t t0 = 20000 + i * 120;
        a = at(&k, t0, IB_KEY_DOWN, IB_KEY_EV_DOWN); downs += a.send;
        a = at(&k, t0 + 50, IB_KEY_DOWN, IB_KEY_EV_UP); ups += a.send;
    }
    CHECK(downs == 5 && ups == 5);

    // 熄屏唤醒的那次按压被吞掉后,回弹窗口同样生效,且不影响之后的真实按键。
    a = ib_keys_handle(&k, IB_KEY_UP, IB_KEY_EV_DOWN, 30000, true, true, false);
    CHECK(!a.send);
    a = at(&k, 30100, IB_KEY_UP, IB_KEY_EV_UP);
    CHECK(!a.send);
    a = at(&k, 30120, IB_KEY_UP, IB_KEY_EV_DOWN);
    CHECK(!a.send);
    a = at(&k, 30300, IB_KEY_UP, IB_KEY_EV_DOWN);
    CHECK(a.send);
}

static void test_keys(void)
{
    ib_keys_t k;
    ib_keys_reset(&k);
    ib_key_action_t a;

    // 正常按压:down / long / up 都上报,无 ack。
    a = H(&k, IB_KEY_OK, IB_KEY_EV_DOWN, true, false, false);
    CHECK(a.send && !a.ack && !a.dismiss_agent);
    a = H(&k, IB_KEY_OK, IB_KEY_EV_DOWN, true, false, false);     // 重复 down
    CHECK(!a.send);
    a = H(&k, IB_KEY_OK, IB_KEY_EV_LONG, true, false, false);
    CHECK(a.send && !a.ack);
    a = H(&k, IB_KEY_OK, IB_KEY_EV_UP, true, false, false);
    CHECK(a.send && !a.ack);
    a = H(&k, IB_KEY_OK, IB_KEY_EV_UP, true, false, false);       // 没有 down 的 up
    CHECK(!a.send);

    // 熄屏时按下只点亮屏幕:整次按压都不上报。
    a = H(&k, IB_KEY_UP, IB_KEY_EV_DOWN, true, true, false);
    CHECK(!a.send);
    a = H(&k, IB_KEY_UP, IB_KEY_EV_LONG, true, false, false);
    CHECK(!a.send);
    a = H(&k, IB_KEY_UP, IB_KEY_EV_UP, true, false, false);
    CHECK(!a.send);

    // 离线:不上报。
    a = H(&k, IB_KEY_DOWN, IB_KEY_EV_DOWN, false, false, false);
    CHECK(!a.send);
    a = H(&k, IB_KEY_DOWN, IB_KEY_EV_UP, false, false, false);
    CHECK(!a.send);

    // Agent 通知:关闭通知的按压 down/long/up 都带 ack,下一次按压恢复正常。
    a = H(&k, IB_KEY_UP, IB_KEY_EV_DOWN, true, false, true);
    CHECK(a.send && a.ack && a.dismiss_agent);
    a = H(&k, IB_KEY_UP, IB_KEY_EV_LONG, true, false, false);
    CHECK(a.send && a.ack && !a.dismiss_agent);
    a = H(&k, IB_KEY_UP, IB_KEY_EV_UP, true, false, false);
    CHECK(a.send && a.ack);
    a = H(&k, IB_KEY_UP, IB_KEY_EV_DOWN, true, false, false);
    CHECK(a.send && !a.ack);
    a = H(&k, IB_KEY_UP, IB_KEY_EV_UP, true, false, false);
    CHECK(a.send && !a.ack);

    // 按住期间 Mac 掉线:up 不上报,状态复位。
    a = H(&k, IB_KEY_OK, IB_KEY_EV_DOWN, true, false, false);
    CHECK(a.send);
    a = H(&k, IB_KEY_OK, IB_KEY_EV_UP, false, false, false);
    CHECK(!a.send);
    CHECK(!k.pressed[IB_KEY_OK]);

    // reset 清空按下状态。
    H(&k, IB_KEY_DOWN, IB_KEY_EV_DOWN, true, false, false);
    ib_keys_reset(&k);
    a = H(&k, IB_KEY_DOWN, IB_KEY_EV_UP, true, false, false);
    CHECK(!a.send);
    a = H(&k, IB_KEY_COUNT, IB_KEY_EV_DOWN, true, false, false);
    CHECK(!a.send);
}

static void test_links(void)
{
    ib_links_t l;
    ib_links_init(&l);
    CHECK(!ib_links_any(&l, 1000));
    CHECK(ib_links_preferred(&l, 1000) == IB_LINK_COUNT);

    ib_links_seen(&l, IB_LINK_BLE, 1000);
    CHECK(ib_links_alive(&l, IB_LINK_BLE, 1000));
    CHECK(ib_links_preferred(&l, 1000) == IB_LINK_BLE);
    CHECK(ib_links_alive(&l, IB_LINK_BLE, 1000 + IB_LINK_TIMEOUT_MS - 1));
    CHECK(!ib_links_alive(&l, IB_LINK_BLE, 1000 + IB_LINK_TIMEOUT_MS));

    // Mac 切到 USB 后直接断 BLE(不发 bye):USB 仍在线。
    ib_links_seen(&l, IB_LINK_USB, 2000);
    CHECK(ib_links_preferred(&l, 2000) == IB_LINK_USB);
    ib_links_drop(&l, IB_LINK_BLE);
    CHECK(ib_links_any(&l, 2000));
    CHECK(ib_links_preferred(&l, 2000) == IB_LINK_USB);
    ib_links_drop(&l, IB_LINK_USB);
    CHECK(!ib_links_any(&l, 2000));

    ib_links_seen(&l, IB_LINK_USB, 0);     // now=0 也视为在线(内部记为 1)
    CHECK(ib_links_alive(&l, IB_LINK_USB, 10));
}

// USB 在位去抖:SOF 检测偶尔读到 false 不应判离线,真拔线 1 s 后才判离线。
static void test_usb_present(void)
{
    ib_links_t l;
    ib_links_init(&l);
    // 开机没接 USB:一直不在位,不经过去抖窗口。
    CHECK(!ib_links_usb_present(&l, false, 100));
    // 插线立即在位。
    CHECK(ib_links_usb_present(&l, true, 200));

    // 短暂 false(SOF 中断几十毫秒)不判离线。
    CHECK(ib_links_usb_present(&l, false, 1000));
    CHECK(ib_links_usb_present(&l, false, 1300));
    CHECK(ib_links_usb_present(&l, true, 1400));
    // 恢复在位后计时清零:再次读到 false 重新计 1 s。
    CHECK(ib_links_usb_present(&l, false, 1500));
    CHECK(ib_links_usb_present(&l, false, 1500 + IB_USB_ABSENT_CONFIRM_MS - 1));
    CHECK(ib_links_usb_present(&l, true, 1500 + IB_USB_ABSENT_CONFIRM_MS - 1));

    // 真拔线:连续 false 满 1 s 判离线,之后保持不在位。
    CHECK(ib_links_usb_present(&l, false, 5000));
    CHECK(ib_links_usb_present(&l, false, 5000 + IB_USB_ABSENT_CONFIRM_MS - 1));
    CHECK(!ib_links_usb_present(&l, false, 5000 + IB_USB_ABSENT_CONFIRM_MS));
    CHECK(!ib_links_usb_present(&l, false, 9000));

    // 读到 false 期间收到 USB 命令:主机仍在,计时从命令时刻重新开始。
    CHECK(ib_links_usb_present(&l, true, 10000));
    CHECK(ib_links_usb_present(&l, false, 10000));
    ib_links_seen(&l, IB_LINK_USB, 10800);
    CHECK(ib_links_usb_present(&l, false, 10000 + IB_USB_ABSENT_CONFIRM_MS));
    CHECK(ib_links_usb_present(&l, false, 10800 + IB_USB_ABSENT_CONFIRM_MS - 1));
    CHECK(!ib_links_usb_present(&l, false, 10800 + IB_USB_ABSENT_CONFIRM_MS));

    // 去抖只做判定,不改链路在线状态(由调用方 drop)。
    CHECK(ib_links_alive(&l, IB_LINK_USB, 10800 + IB_USB_ABSENT_CONFIRM_MS));
}

int main(void)
{
    test_keys();
    test_bounce();
    test_links();
    test_usb_present();
    TEST_DONE("test_ib_keys");
}
