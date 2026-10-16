// main/ib_protocol.h: InputBetter Passport 协议 v1(见仓库 docs/protocol.md)。
// 纯 C 实现,不依赖 ESP-IDF/LVGL,由 tests/test_ib_protocol.c 在主机上测试。
#pragma once

#include "ib_icons.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define IB_FIRMWARE_NAME    "inputbetter"
#define IB_PROTO_VERSION    1

// 单行上限(含 NUL):协议规定单行最长 511 字节。
#define IB_LINE_MAX         512
// 屏幕文本字段(msg / engine)上限(含 NUL):协议规定最长 23 字节 ASCII。
#define IB_TEXT_MAX         24
// list 命令一次最多携带的可见行数(i0..i5);i6 及以后视为未知字段忽略。
#define IB_LIST_ROWS        6
// list 命令里 n / sel / top 的上限。
#define IB_LIST_MAX         65535
// 设备发出的单条消息缓冲。
#define IB_MSG_MAX          128
// config.screen_off 上限(秒),超出按上限处理。
#define IB_SCREEN_OFF_MAX_S 86400

// 二进制帧:FF FE type seq len_lo len_hi + 负载(1..1024 字节)。
#define IB_BIN_SYNC0        0xFF
#define IB_BIN_SYNC1        0xFE
#define IB_BIN_HDR          6
#define IB_BIN_MAX          1024
#define IB_BIN_ADPCM        0x02    // 设备 → Mac:1~2 块 IMA ADPCM(见 ib_adpcm.h)

typedef enum {
    IB_KEY_UP = 0,
    IB_KEY_DOWN,
    IB_KEY_OK,
    IB_KEY_COUNT,
} ib_key_t;

typedef enum {
    IB_KEY_EV_DOWN = 0,     // 按下瞬间
    IB_KEY_EV_UP,           // 松开
    IB_KEY_EV_LONG,         // 按住 1 秒
    IB_KEY_EV_COUNT,
} ib_key_ev_t;

typedef enum {
    IB_ST_IDLE = 0,
    IB_ST_REC,
    IB_ST_PROC,
    IB_ST_DONE,
    IB_ST_ERR,
    IB_ST_SUB,
    IB_ST_LIST,             // 列表页(Mac 驱动的应用切换器等),内容由 list 命令提供
    IB_ST_COUNT,
} ib_state_t;

typedef enum {
    IB_MODE_DICT = 0,
    IB_MODE_TR,
    IB_MODE_SUB,
    IB_MODE_COUNT,
} ib_mode_t;

typedef enum {
    IB_AGENT_DONE = 0,      // Agent 任务完成
    IB_AGENT_INPUT,         // Agent 等待你确认 / 输入
    IB_AGENT_CLEAR,         // 撤销通知
    IB_AGENT_COUNT,
} ib_agent_ev_t;

typedef enum {
    IB_CMD_HELLO = 0,
    IB_CMD_PING,
    IB_CMD_BYE,
    IB_CMD_CONFIG,
    IB_CMD_STATE,
    IB_CMD_LEVEL,
    IB_CMD_MIC,
    IB_CMD_KEYS,
    IB_CMD_AGENT,
    IB_CMD_LIST,
} ib_cmd_type_t;

typedef struct {
    ib_cmd_type_t type;
    // config(字段都可选)
    bool has_mic;
    bool mic;                       // 听写音源是 Passport 麦克风
    bool has_engine;
    char engine[IB_TEXT_MAX];
    bool has_screen_off;
    uint32_t screen_off_s;          // 0 为永不熄屏
    bool has_clock;
    uint32_t clock;                 // Mac 本地时间(Unix 秒 + 时区偏移)
    bool has_sound;
    bool sound;
    // state(st 必填)
    bool has_state;
    ib_state_t state;
    bool has_mode;
    ib_mode_t mode;
    bool has_msg;
    char msg[IB_TEXT_MAX];          // state 的短文本;agent 的来源名
    // level(v 必填,超过 100 按 100)
    bool has_level;
    uint8_t level;
    // mic(on 必填)
    bool has_on;
    bool on;
    // keys(字段可选;出现的字段才更新)。值为图标 id,空串或未知 id 解析为 IB_ICON_NONE(隐藏)。
    // 下标为 ib_key_t。
    bool has_key_icon[IB_KEY_COUNT];
    ib_icon_t key_icon[IB_KEY_COUNT];
    // agent(ev 必填,msg 可选)
    bool has_agent_ev;
    ib_agent_ev_t agent_ev;
    // list(n、sel 必填;title、top、i0..i5 可选)。选中项由 Mac 维护,设备只负责显示。
    char list_title[IB_TEXT_MAX];
    char list_item[IB_LIST_ROWS][IB_TEXT_MAX];
    uint8_t list_rows;              // 出现过的最大 i<k> 序号 + 1(中间缺的行为空串)
    bool has_list_n;
    uint16_t list_n;                // 列表总项数
    bool has_list_sel;
    uint16_t list_sel;              // 选中项的绝对序号
    uint16_t list_top;              // i0 在完整列表里的序号(缺省 0)
} ib_cmd_t;

const char *ib_key_name(ib_key_t key);          // "up" / "down" / "ok";越界 "?"
const char *ib_key_ev_name(ib_key_ev_t ev);     // "down" / "up" / "long";越界 "?"
const char *ib_state_name(ib_state_t st);
const char *ib_mode_name(ib_mode_t mode);
const char *ib_agent_ev_name(ib_agent_ev_t ev);

// 以下函数写入一行以 '\n' 结尾、NUL 终止的 JSON,返回不含 NUL 的长度;放不下或参数非法时返回 0。
// build:固件构建标识,ELF 文件 SHA-256 的前 8 位小写十六进制(必须恰好 8 个 [0-9a-f],否则返回 0)。
// Mac 端用同一算法(shasum -a 256 InputBetter-Passport.elf 的前 8 位)判断设备固件是否与 app 内置的一致。
#define IB_BUILD_ID_LEN 8
size_t ib_format_hello(char *buf, size_t cap, const char *version, const char *build, uint32_t boot_id);
// ack=true 时附加 "ack":1:这次按压用于关闭 agent 通知,Mac 不执行它的动作。
size_t ib_format_key(char *buf, size_t cap, ib_key_t key, ib_key_ev_t ev, bool ack, uint32_t seq, uint32_t boot_id);
size_t ib_format_battery(char *buf, size_t cap, int soc, int mv, bool charging);
size_t ib_format_pong(char *buf, size_t cap);

// 写二进制帧头;payload_len 不在 1..IB_BIN_MAX 时返回 0。
size_t ib_bin_header(uint8_t out[IB_BIN_HDR], uint8_t type, uint8_t seq, size_t payload_len);

// 解析一行 Mac 命令(不含 '\n')。只接受扁平 JSON 对象:字符串值与非负整数值;
// 未知字段忽略(其值可以是任意标量),未知命令、未知 st、缺必填字段、已知字段类型错误时返回 false。
// 文本里的非 ASCII 字符折叠为 '?',msg/engine/title/列表项超过 23 字节截断。
// list:n、sel 超过 65535 或 n>0 时 sel>=n、top>=n 判为非法。
bool ib_parse_command(const char *line, size_t len, ib_cmd_t *out);

// 按 '\n' 组帧。USB 读取与 BLE 写入都可能把一行拆成多段,每条链路各持有一个实例。
// Mac → 设备方向没有二进制帧;0xFF 起始的字节序列按普通字节处理,只会让该行解析失败。
typedef struct {
    char buf[IB_LINE_MAX];
    size_t len;
    bool discarding;        // 当前行已超长,丢弃到下一个 '\n'
} ib_line_t;

// 每收到完整一行回调一次;line 以 NUL 结尾,不含 '\r\n',空行不回调。
typedef void (*ib_line_cb_t)(const char *line, size_t len, void *user);

void ib_line_init(ib_line_t *line);
void ib_line_feed(ib_line_t *line, const uint8_t *data, size_t len, ib_line_cb_t cb, void *user);
