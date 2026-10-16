// main/ib_protocol.c: InputBetter 协议的纯逻辑实现(消息格式化、命令解析、行组帧)。
#include "ib_protocol.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static const char *const KEY_NAMES[IB_KEY_COUNT] = { "up", "down", "ok" };
static const char *const KEY_EV_NAMES[IB_KEY_EV_COUNT] = { "down", "up", "long" };
static const char *const STATE_NAMES[IB_ST_COUNT] = { "idle", "rec", "proc", "done", "err", "sub", "list" };
static const char *const MODE_NAMES[IB_MODE_COUNT] = { "dict", "tr", "sub" };
static const char *const AGENT_EV_NAMES[IB_AGENT_COUNT] = { "done", "input", "clear" };

const char *ib_key_name(ib_key_t key)
{
    return (unsigned)key < IB_KEY_COUNT ? KEY_NAMES[key] : "?";
}

const char *ib_key_ev_name(ib_key_ev_t ev)
{
    return (unsigned)ev < IB_KEY_EV_COUNT ? KEY_EV_NAMES[ev] : "?";
}

const char *ib_state_name(ib_state_t st)
{
    return (unsigned)st < IB_ST_COUNT ? STATE_NAMES[st] : "?";
}

const char *ib_mode_name(ib_mode_t mode)
{
    return (unsigned)mode < IB_MODE_COUNT ? MODE_NAMES[mode] : "?";
}

const char *ib_agent_ev_name(ib_agent_ev_t ev)
{
    return (unsigned)ev < IB_AGENT_COUNT ? AGENT_EV_NAMES[ev] : "?";
}

// snprintf 截断时返回值 >= cap:视为失败,绝不发出半行 JSON。
static size_t finish(int n, size_t cap)
{
    return (n > 0 && (size_t)n < cap) ? (size_t)n : 0;
}

size_t ib_format_hello(char *buf, size_t cap, const char *version, const char *build, uint32_t boot_id)
{
    for (int i = 0; i < IB_BUILD_ID_LEN; i++) {
        char ch = build[i];
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return 0;
    }
    if (build[IB_BUILD_ID_LEN] != '\0') return 0;
    // 版本号只允许可打印 ASCII 且不含引号/反斜杠,否则会破坏 JSON。
    for (const char *p = version; *p; p++) {
        if (*p < 0x20 || *p >= 0x7F || *p == '"' || *p == '\\') return 0;
    }
    return finish(snprintf(buf, cap,
                           "{\"t\":\"hello\",\"fw\":\"" IB_FIRMWARE_NAME "\",\"proto\":%d,"
                           "\"ver\":\"%s\",\"build\":\"%s\",\"boot\":\"%08" PRIx32 "\"}\n",
                           IB_PROTO_VERSION, version, build, boot_id),
                  cap);
}

size_t ib_format_key(char *buf, size_t cap, ib_key_t key, ib_key_ev_t ev, bool ack, uint32_t seq, uint32_t boot_id)
{
    if ((unsigned)key >= IB_KEY_COUNT || (unsigned)ev >= IB_KEY_EV_COUNT) return 0;
    return finish(snprintf(buf, cap,
                           "{\"t\":\"key\",\"k\":\"%s\",\"e\":\"%s\",%s\"seq\":%" PRIu32 ",\"boot\":\"%08" PRIx32 "\"}\n",
                           KEY_NAMES[key], KEY_EV_NAMES[ev], ack ? "\"ack\":1," : "", seq, boot_id),
                  cap);
}

size_t ib_format_battery(char *buf, size_t cap, int soc, int mv, bool charging)
{
    if (soc < 0 || soc > 100) soc = -1;
    if (mv < 0) mv = -1;
    return finish(snprintf(buf, cap, "{\"t\":\"bat\",\"soc\":%d,\"mv\":%d,\"chg\":%d}\n", soc, mv, charging ? 1 : 0),
                  cap);
}

size_t ib_format_pong(char *buf, size_t cap)
{
    return finish(snprintf(buf, cap, "{\"t\":\"pong\"}\n"), cap);
}

size_t ib_bin_header(uint8_t out[IB_BIN_HDR], uint8_t type, uint8_t seq, size_t payload_len)
{
    if (payload_len == 0 || payload_len > IB_BIN_MAX) return 0;
    out[0] = IB_BIN_SYNC0;
    out[1] = IB_BIN_SYNC1;
    out[2] = type;
    out[3] = seq;
    out[4] = (uint8_t)(payload_len & 0xFF);
    out[5] = (uint8_t)(payload_len >> 8);
    return IB_BIN_HDR;
}

// ---------------------------------------------------------------------------
// 命令解析:只覆盖扁平对象的 JSON 子集,固定栈内存,不做堆分配。
// ---------------------------------------------------------------------------

typedef struct {
    const char *p;
    const char *end;
} cursor_t;

static void skip_ws(cursor_t *c)
{
    while (c->p < c->end && (*c->p == ' ' || *c->p == '\t' || *c->p == '\r' || *c->p == '\n')) c->p++;
}

static int hex_digit(char ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

static bool read_hex4(cursor_t *c, unsigned *out)
{
    if (c->end - c->p < 4) return false;
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        int h = hex_digit(c->p[i]);
        if (h < 0) return false;
        v = v * 16U + (unsigned)h;
    }
    c->p += 4;
    *out = v;
    return true;
}

// 读取 JSON 字符串到 out(容量 cap,总以 NUL 结尾,超长截断)。
// 屏幕只有 ASCII 字体:每个非 ASCII 字符(UTF-8 多字节序列、\u 转义、代理对)折叠为一个 '?'。
static bool read_string(cursor_t *c, char *out, size_t cap)
{
    if (c->p >= c->end || *c->p != '"' || cap == 0) return false;
    c->p++;
    size_t n = 0;
    while (c->p < c->end) {
        unsigned char ch = (unsigned char)*c->p++;
        int v;
        if (ch == '"') {
            out[n] = '\0';
            return true;
        }
        if (ch == '\\') {
            if (c->p >= c->end) return false;
            char esc = *c->p++;
            switch (esc) {
            case '"': v = '"'; break;
            case '\\': v = '\\'; break;
            case '/': v = '/'; break;
            case 'b': case 'f': case 'n': case 'r': case 't': v = ' '; break;
            case 'u': {
                unsigned code;
                if (!read_hex4(c, &code)) return false;
                if (code >= 0xD800 && code <= 0xDBFF && c->end - c->p >= 6 && c->p[0] == '\\' && c->p[1] == 'u') {
                    cursor_t peek = { c->p + 2, c->end };
                    unsigned low;
                    if (read_hex4(&peek, &low) && low >= 0xDC00 && low <= 0xDFFF) c->p = peek.p;
                }
                v = (code >= 0x20 && code < 0x7F) ? (int)code : '?';
                break;
            }
            default:
                return false;
            }
        } else if (ch < 0x20) {
            return false;
        } else if (ch >= 0x80) {
            if ((ch & 0xC0) == 0x80) continue;      // UTF-8 续字节:首字节已输出 '?'
            v = '?';
        } else {
            v = ch;
        }
        if (n + 1 < cap) out[n++] = (char)v;
    }
    return false;
}

// 跳过未知字段的标量值(数字、true/false/null,含负数与小数)。嵌套对象/数组视为非法。
static bool skip_scalar(cursor_t *c)
{
    const char *start = c->p;
    while (c->p < c->end) {
        char ch = *c->p;
        if (ch == ',' || ch == '}' || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') break;
        if (ch == '{' || ch == '[' || ch == '"' || ch == ':') return false;
        c->p++;
    }
    return c->p > start;
}

// 读取非负整数(不接受负号、前导零、小数、指数);超过 max 时截到 max(clamp=true)或判为非法。
static bool read_uint(cursor_t *c, uint32_t max, bool clamp, uint32_t *out)
{
    const char *start = c->p;
    uint64_t v = 0;
    bool over = false;
    while (c->p < c->end && *c->p >= '0' && *c->p <= '9') {
        if (!over) {
            v = v * 10U + (uint64_t)(*c->p - '0');
            if (v > max) over = true;
        }
        c->p++;
    }
    size_t digits = (size_t)(c->p - start);
    if (digits == 0 || (digits > 1 && *start == '0')) return false;
    if (over) {
        if (!clamp) return false;
        v = max;
    }
    *out = (uint32_t)v;
    return true;
}

static int lookup(const char *s, const char *const *names, int count)
{
    for (int i = 0; i < count; i++) {
        if (strcmp(s, names[i]) == 0) return i;
    }
    return -1;
}

typedef enum { VAL_STR, VAL_UINT } val_kind_t;

static const char *const KNOWN_KEYS[] = {
    "cmd", "mic", "engine", "screen_off", "clock", "sound", "st", "mode", "msg", "v", "on",
    "ok", "up", "down", "ev",
    "title", "n", "sel", "top", "i0", "i1", "i2", "i3", "i4", "i5",
};

static bool is_known_key(const char *key)
{
    return lookup(key, KNOWN_KEYS, (int)(sizeof(KNOWN_KEYS) / sizeof(KNOWN_KEYS[0]))) >= 0;
}

bool ib_parse_command(const char *line, size_t len, ib_cmd_t *out)
{
    memset(out, 0, sizeof(*out));
    cursor_t c = { line, line + len };
    char cmd[16] = "";
    bool has_cmd = false;
    bool bad_state = false;
    bool bad_agent = false;

    skip_ws(&c);
    if (c.p >= c.end || *c.p != '{') return false;
    c.p++;
    skip_ws(&c);
    if (c.p < c.end && *c.p == '}') return false;   // 空对象没有 cmd

    for (;;) {
        char key[16];
        char text[IB_TEXT_MAX];
        uint32_t num = 0;
        val_kind_t kind;

        skip_ws(&c);
        if (!read_string(&c, key, sizeof(key))) return false;
        skip_ws(&c);
        if (c.p >= c.end || *c.p != ':') return false;
        c.p++;
        skip_ws(&c);
        if (c.p >= c.end) return false;

        if (!is_known_key(key)) {
            // 未知字段:值可以是字符串或任意标量,读过即忽略。
            if (*c.p == '"') {
                if (!read_string(&c, text, sizeof(text))) return false;
            } else if (!skip_scalar(&c)) {
                return false;
            }
            goto next;
        }
        if (*c.p == '"') {
            if (!read_string(&c, text, sizeof(text))) return false;
            kind = VAL_STR;
        } else {
            // 已知字段只接受字符串或非负整数;负数、小数、布尔、null 使整条命令无效。
            if (!read_uint(&c, UINT32_MAX, true, &num)) return false;
            kind = VAL_UINT;
        }

        if (strcmp(key, "cmd") == 0) {
            if (kind != VAL_STR) return false;
            if (strlen(text) >= sizeof(cmd)) return false;     // 没有这么长的命令名
            memcpy(cmd, text, strlen(text) + 1);
            has_cmd = true;
        } else if (strcmp(key, "engine") == 0 || strcmp(key, "msg") == 0) {
            if (kind != VAL_STR) return false;
            if (key[0] == 'e') {
                memcpy(out->engine, text, sizeof(text));
                out->has_engine = true;
            } else {
                memcpy(out->msg, text, sizeof(text));
                out->has_msg = true;
            }
        } else if (strcmp(key, "st") == 0) {
            if (kind != VAL_STR) return false;
            int st = lookup(text, STATE_NAMES, IB_ST_COUNT);
            if (st < 0) {
                bad_state = true;
            } else {
                out->state = (ib_state_t)st;
                out->has_state = true;
            }
        } else if (strcmp(key, "ok") == 0 || strcmp(key, "up") == 0 || strcmp(key, "down") == 0) {
            if (kind != VAL_STR) return false;
            int k = lookup(key, KEY_NAMES, IB_KEY_COUNT);
            // 图标 id 未知时按"无动作"处理(隐藏),不拒绝整条:Mac 新增图标时旧固件仍能显示其它键。
            out->key_icon[k] = ib_icon_from_id(text);
            out->has_key_icon[k] = true;
        } else if (strcmp(key, "ev") == 0) {
            if (kind != VAL_STR) return false;
            int ev = lookup(text, AGENT_EV_NAMES, IB_AGENT_COUNT);
            if (ev < 0) {
                bad_agent = true;
            } else {
                out->agent_ev = (ib_agent_ev_t)ev;
                out->has_agent_ev = true;
            }
        } else if (strcmp(key, "mode") == 0) {
            if (kind != VAL_STR) return false;
            int mode = lookup(text, MODE_NAMES, IB_MODE_COUNT);
            // 未知 mode 忽略该字段,保留设备当前模式。
            if (mode >= 0) {
                out->mode = (ib_mode_t)mode;
                out->has_mode = true;
            }
        } else if (strcmp(key, "mic") == 0 || strcmp(key, "sound") == 0 || strcmp(key, "on") == 0) {
            if (kind != VAL_UINT) return false;
            if (key[0] == 'm') {
                out->has_mic = true;
                out->mic = num != 0;
            } else if (key[0] == 's') {
                out->has_sound = true;
                out->sound = num != 0;
            } else {
                out->has_on = true;
                out->on = num != 0;
            }
        } else if (strcmp(key, "screen_off") == 0) {
            if (kind != VAL_UINT) return false;
            out->screen_off_s = num > IB_SCREEN_OFF_MAX_S ? IB_SCREEN_OFF_MAX_S : num;
            out->has_screen_off = true;
        } else if (strcmp(key, "clock") == 0) {
            if (kind != VAL_UINT) return false;
            out->clock = num;
            out->has_clock = true;
        } else if (strcmp(key, "v") == 0) {
            if (kind != VAL_UINT) return false;
            out->level = (uint8_t)(num > 100 ? 100 : num);
            out->has_level = true;
        } else if (strcmp(key, "title") == 0) {
            if (kind != VAL_STR) return false;
            memcpy(out->list_title, text, sizeof(text));
        } else if (key[0] == 'i' && key[1] >= '0' && key[1] < '0' + IB_LIST_ROWS && key[2] == '\0') {
            if (kind != VAL_STR) return false;
            int row = key[1] - '0';
            memcpy(out->list_item[row], text, sizeof(text));
            if (row + 1 > out->list_rows) out->list_rows = (uint8_t)(row + 1);
        } else if (strcmp(key, "n") == 0 || strcmp(key, "sel") == 0 || strcmp(key, "top") == 0) {
            if (kind != VAL_UINT || num > IB_LIST_MAX) return false;
            if (key[0] == 'n') {
                out->list_n = (uint16_t)num;
                out->has_list_n = true;
            } else if (key[0] == 's') {
                out->list_sel = (uint16_t)num;
                out->has_list_sel = true;
            } else {
                out->list_top = (uint16_t)num;
            }
        }

    next:
        skip_ws(&c);
        if (c.p >= c.end) return false;
        if (*c.p == ',') {
            c.p++;
            continue;
        }
        if (*c.p != '}') return false;
        c.p++;
        break;
    }
    skip_ws(&c);
    if (c.p != c.end || !has_cmd) return false;

    if (strcmp(cmd, "hello") == 0) {
        out->type = IB_CMD_HELLO;
    } else if (strcmp(cmd, "ping") == 0) {
        out->type = IB_CMD_PING;
    } else if (strcmp(cmd, "bye") == 0) {
        out->type = IB_CMD_BYE;
    } else if (strcmp(cmd, "config") == 0) {
        out->type = IB_CMD_CONFIG;
    } else if (strcmp(cmd, "state") == 0) {
        if (bad_state || !out->has_state) return false;
        out->type = IB_CMD_STATE;
    } else if (strcmp(cmd, "level") == 0) {
        if (!out->has_level) return false;
        out->type = IB_CMD_LEVEL;
    } else if (strcmp(cmd, "mic") == 0) {
        if (!out->has_on) return false;
        out->type = IB_CMD_MIC;
    } else if (strcmp(cmd, "keys") == 0) {
        out->type = IB_CMD_KEYS;
    } else if (strcmp(cmd, "agent") == 0) {
        if (bad_agent || !out->has_agent_ev) return false;
        out->type = IB_CMD_AGENT;
    } else if (strcmp(cmd, "list") == 0) {
        if (!out->has_list_n || !out->has_list_sel) return false;
        if (out->list_n > 0 && (out->list_sel >= out->list_n || out->list_top >= out->list_n)) return false;
        out->type = IB_CMD_LIST;
    } else {
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 行组帧
// ---------------------------------------------------------------------------

void ib_line_init(ib_line_t *line)
{
    line->len = 0;
    line->discarding = false;
}

void ib_line_feed(ib_line_t *line, const uint8_t *data, size_t len, ib_line_cb_t cb, void *user)
{
    for (size_t i = 0; i < len; i++) {
        uint8_t b = data[i];
        if (b == '\n') {
            if (!line->discarding) {
                if (line->len > 0 && line->buf[line->len - 1] == '\r') line->len--;
                if (line->len > 0) {
                    line->buf[line->len] = '\0';
                    if (cb) cb(line->buf, line->len, user);
                }
            }
            line->len = 0;
            line->discarding = false;
        } else if (line->discarding) {
            continue;
        } else if (line->len + 1 >= sizeof(line->buf)) {
            // 超长行整行丢弃,不把残片当成命令。
            line->len = 0;
            line->discarding = true;
        } else {
            line->buf[line->len++] = (char)b;
        }
    }
}
