// main/ib_keys.c: 按键事件过滤实现(见 ib_keys.h)。
#include "ib_keys.h"

#include <string.h>

void ib_keys_reset(ib_keys_t *k)
{
    memset(k, 0, sizeof(*k));
}

ib_key_action_t ib_keys_handle(ib_keys_t *k, ib_key_t key, ib_key_ev_t ev, int64_t now_ms, bool online,
                               bool screen_dark, bool agent_capture)
{
    ib_key_action_t act = { false, false, false };
    if ((unsigned)key >= IB_KEY_COUNT) return act;

    switch (ev) {
    case IB_KEY_EV_DOWN:
        if (k->pressed[key]) break;                 // 重复的按下
        k->ack[key] = false;
        // 松开回弹:紧跟在松开之后的按下不是真实按键。pressed 保持 false,随后的 up/long 也会被忽略。
        if (k->has_up[key] && now_ms - k->last_up_ms[key] < IB_KEYS_REPRESS_LOCKOUT_MS) break;
        if (!online || screen_dark) break;          // 只点亮屏幕
        k->pressed[key] = true;
        if (agent_capture) {
            k->ack[key] = true;
            act.dismiss_agent = true;
        }
        act.send = true;
        act.ack = k->ack[key];
        break;
    case IB_KEY_EV_UP:
        // 无论这次按压是否上报,都记录松开时刻(回弹窗口从最后一次松开算起)。
        k->has_up[key] = true;
        k->last_up_ms[key] = now_ms;
        if (!k->pressed[key]) break;
        k->pressed[key] = false;
        act.send = online;
        act.ack = k->ack[key];
        k->ack[key] = false;
        break;
    case IB_KEY_EV_LONG:
        if (!k->pressed[key]) break;
        act.send = online;
        act.ack = k->ack[key];
        break;
    default:
        break;
    }
    return act;
}
