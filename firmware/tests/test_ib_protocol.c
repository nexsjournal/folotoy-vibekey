// tests/test_ib_protocol.c: ib_protocol 主机测试,不依赖 ESP-IDF。
#include "ib_protocol.h"
#include "test_common.h"

static bool parse(const char *line, ib_cmd_t *cmd)
{
    return ib_parse_command(line, strlen(line), cmd);
}

static void test_format(void)
{
    char buf[IB_MSG_MAX];

    CHECK(ib_format_hello(buf, sizeof(buf), "0.1.0", "1a2b3c4d", 0x9f3a21c4) == strlen(buf));
    CHECK_STR(buf, "{\"t\":\"hello\",\"fw\":\"inputbetter\",\"proto\":1,\"ver\":\"0.1.0\","
                   "\"build\":\"1a2b3c4d\",\"boot\":\"9f3a21c4\"}\n");
    CHECK(strlen(buf) < IB_LINE_MAX);
    CHECK(ib_format_hello(buf, sizeof(buf), "bad\"ver", "1a2b3c4d", 1) == 0);
    // build 必须恰好 8 位小写十六进制。
    CHECK(ib_format_hello(buf, sizeof(buf), "0.1.0", "1A2B3C4D", 1) == 0);
    CHECK(ib_format_hello(buf, sizeof(buf), "0.1.0", "1a2b3c4", 1) == 0);
    CHECK(ib_format_hello(buf, sizeof(buf), "0.1.0", "1a2b3c4d5", 1) == 0);
    CHECK(ib_format_hello(buf, sizeof(buf), "0.1.0", "1a2b3c4g", 1) == 0);

    CHECK(ib_format_key(buf, sizeof(buf), IB_KEY_OK, IB_KEY_EV_DOWN, false, 12, 0x9f3a21c4) > 0);
    CHECK_STR(buf, "{\"t\":\"key\",\"k\":\"ok\",\"e\":\"down\",\"seq\":12,\"boot\":\"9f3a21c4\"}\n");
    CHECK(ib_format_key(buf, sizeof(buf), IB_KEY_DOWN, IB_KEY_EV_LONG, false, 4294967295U, 1) > 0);
    CHECK_STR(buf, "{\"t\":\"key\",\"k\":\"down\",\"e\":\"long\",\"seq\":4294967295,\"boot\":\"00000001\"}\n");
    CHECK(ib_format_key(buf, sizeof(buf), IB_KEY_UP, IB_KEY_EV_UP, false, 0, 0xabcdef01) > 0);
    CHECK_STR(buf, "{\"t\":\"key\",\"k\":\"up\",\"e\":\"up\",\"seq\":0,\"boot\":\"abcdef01\"}\n");
    // 关闭 agent 通知的那次按压带 "ack":1。
    CHECK(ib_format_key(buf, sizeof(buf), IB_KEY_UP, IB_KEY_EV_DOWN, true, 7, 0x9f3a21c4) > 0);
    CHECK_STR(buf, "{\"t\":\"key\",\"k\":\"up\",\"e\":\"down\",\"ack\":1,\"seq\":7,\"boot\":\"9f3a21c4\"}\n");
    CHECK(ib_format_key(buf, sizeof(buf), IB_KEY_COUNT, IB_KEY_EV_UP, false, 0, 0) == 0);
    CHECK(ib_format_key(buf, sizeof(buf), IB_KEY_OK, IB_KEY_EV_COUNT, false, 0, 0) == 0);

    CHECK(ib_format_battery(buf, sizeof(buf), 87, 4012, false) > 0);
    CHECK_STR(buf, "{\"t\":\"bat\",\"soc\":87,\"mv\":4012,\"chg\":0}\n");
    CHECK(ib_format_battery(buf, sizeof(buf), -1, -5, true) > 0);
    CHECK_STR(buf, "{\"t\":\"bat\",\"soc\":-1,\"mv\":-1,\"chg\":1}\n");
    CHECK(ib_format_battery(buf, sizeof(buf), 255, 3700, false) > 0);
    CHECK_STR(buf, "{\"t\":\"bat\",\"soc\":-1,\"mv\":3700,\"chg\":0}\n");

    CHECK(ib_format_pong(buf, sizeof(buf)) > 0);
    CHECK_STR(buf, "{\"t\":\"pong\"}\n");
    char tiny[12];
    CHECK(ib_format_pong(tiny, sizeof(tiny)) == 0);

    uint8_t hdr[IB_BIN_HDR];
    CHECK(ib_bin_header(hdr, IB_BIN_ADPCM, 200, 328) == IB_BIN_HDR);
    CHECK(hdr[0] == 0xFF && hdr[1] == 0xFE && hdr[2] == 0x02 && hdr[3] == 200 && hdr[4] == 0x48 && hdr[5] == 0x01);
    CHECK(ib_bin_header(hdr, IB_BIN_ADPCM, 0, 0) == 0);
    CHECK(ib_bin_header(hdr, IB_BIN_ADPCM, 0, IB_BIN_MAX + 1) == 0);
    CHECK(ib_bin_header(hdr, IB_BIN_ADPCM, 0, IB_BIN_MAX) == IB_BIN_HDR);

    CHECK_STR(ib_key_name(IB_KEY_DOWN), "down");
    CHECK_STR(ib_key_name(IB_KEY_COUNT), "?");
    CHECK_STR(ib_state_name(IB_ST_SUB), "sub");
    CHECK_STR(ib_mode_name(IB_MODE_TR), "tr");
}

static void test_simple(void)
{
    ib_cmd_t c;
    CHECK(parse("{\"cmd\":\"hello\"}", &c) && c.type == IB_CMD_HELLO);
    CHECK(parse(" { \"cmd\" : \"ping\" , \"x\": -12.5e3, \"flag\": true, \"nul\": null, \"s\":\"zz\" } ", &c) &&
          c.type == IB_CMD_PING);
    CHECK(parse("{\"cmd\":\"bye\"}\r", &c) && c.type == IB_CMD_BYE);
    CHECK(parse("{\"extra\":1.5,\"cmd\":\"ping\"}", &c) && c.type == IB_CMD_PING);

    // 非法:未知命令、缺 cmd、嵌套、语法错误、尾随垃圾。
    CHECK(!parse("{\"cmd\":\"reboot\"}", &c));
    CHECK(!parse("{}", &c));
    CHECK(!parse("{\"t\":\"pong\"}", &c));
    CHECK(!parse("{\"cmd\":\"ping\",\"o\":{\"a\":1}}", &c));
    CHECK(!parse("{\"cmd\":\"ping\",\"a\":[1]}", &c));
    CHECK(!parse("{\"cmd\":\"ping\"", &c));
    CHECK(!parse("{\"cmd\":\"ping\"} x", &c));
    CHECK(!parse("{\"cmd\":ping}", &c));
    CHECK(!parse("{\"cmd\":1}", &c));
    CHECK(!parse("{\"cmd\":\"pingpingpingpingping\"}", &c));
    CHECK(!parse("", &c));
}

static void test_config(void)
{
    ib_cmd_t c;
    CHECK(parse("{\"cmd\":\"config\",\"mic\":1,\"engine\":\"Whisper Turbo\",\"screen_off\":60,"
                "\"clock\":1789097696,\"sound\":1}",
                &c));
    CHECK(c.type == IB_CMD_CONFIG);
    CHECK(c.has_mic && c.mic);
    CHECK(c.has_engine);
    CHECK_STR(c.engine, "Whisper Turbo");
    CHECK(c.has_screen_off && c.screen_off_s == 60);
    CHECK(c.has_clock && c.clock == 1789097696U);
    CHECK(c.has_sound && c.sound);

    // 字段都可选。
    CHECK(parse("{\"cmd\":\"config\"}", &c) && c.type == IB_CMD_CONFIG && !c.has_mic && !c.has_engine &&
          !c.has_screen_off && !c.has_clock && !c.has_sound);
    CHECK(parse("{\"cmd\":\"config\",\"mic\":0,\"sound\":0,\"screen_off\":0}", &c) && c.has_mic && !c.mic &&
          c.has_sound && !c.sound && c.has_screen_off && c.screen_off_s == 0);
    // screen_off 超上限按上限;clock 可到 uint32 上限。
    CHECK(parse("{\"cmd\":\"config\",\"screen_off\":999999999999}", &c) && c.screen_off_s == IB_SCREEN_OFF_MAX_S);
    CHECK(parse("{\"cmd\":\"config\",\"clock\":4294967295}", &c) && c.clock == 4294967295U);
    // 已知字段类型错误 → 整条无效。
    CHECK(!parse("{\"cmd\":\"config\",\"mic\":\"1\"}", &c));
    CHECK(!parse("{\"cmd\":\"config\",\"mic\":true}", &c));
    CHECK(!parse("{\"cmd\":\"config\",\"screen_off\":-1}", &c));
    CHECK(!parse("{\"cmd\":\"config\",\"screen_off\":1.5}", &c));
    CHECK(!parse("{\"cmd\":\"config\",\"screen_off\":012}", &c));
    CHECK(!parse("{\"cmd\":\"config\",\"engine\":5}", &c));
    // 引擎名:非 ASCII 折叠为 '?',超过 23 字节截断。
    CHECK(parse("{\"cmd\":\"config\",\"engine\":\"\xE8\xAF\xAD\xE9\x9F\xB3 \\u00e9x\\ud83d\\ude00\"}", &c));
    CHECK_STR(c.engine, "?? ?x?");
    CHECK(parse("{\"cmd\":\"config\",\"engine\":\"ABCDEFGHIJKLMNOPQRSTUVWXYZ\"}", &c));
    CHECK_STR(c.engine, "ABCDEFGHIJKLMNOPQRSTUVW");
    CHECK(strlen(c.engine) == IB_TEXT_MAX - 1);
}

static void test_state(void)
{
    ib_cmd_t c;
    CHECK(parse("{\"cmd\":\"state\",\"st\":\"rec\",\"mode\":\"dict\",\"msg\":\"\"}", &c));
    CHECK(c.type == IB_CMD_STATE && c.has_state && c.state == IB_ST_REC && c.has_mode && c.mode == IB_MODE_DICT &&
          c.has_msg && c.msg[0] == '\0');
    CHECK(parse("{\"cmd\":\"state\",\"st\":\"sub\",\"mode\":\"sub\",\"msg\":\"Chrome\"}", &c));
    CHECK(c.state == IB_ST_SUB && c.mode == IB_MODE_SUB);
    CHECK_STR(c.msg, "Chrome");
    CHECK(parse("{\"cmd\":\"state\",\"st\":\"idle\",\"mode\":\"tr\"}", &c) && c.state == IB_ST_IDLE &&
          c.mode == IB_MODE_TR && !c.has_msg);
    CHECK(parse("{\"cmd\":\"state\",\"st\":\"proc\"}", &c) && c.state == IB_ST_PROC && !c.has_mode);
    CHECK(parse("{\"cmd\":\"state\",\"st\":\"done\",\"msg\":\"Copied\"}", &c) && c.state == IB_ST_DONE);
    CHECK(parse("{\"cmd\":\"state\",\"st\":\"err\",\"msg\":\"No input\"}", &c) && c.state == IB_ST_ERR);
    CHECK_STR(c.msg, "No input");
    // 未知 mode 忽略该字段。
    CHECK(parse("{\"cmd\":\"state\",\"st\":\"idle\",\"mode\":\"karaoke\"}", &c) && !c.has_mode);
    // 缺 st 或未知 st → 整条丢弃。
    CHECK(!parse("{\"cmd\":\"state\",\"mode\":\"dict\"}", &c));
    CHECK(!parse("{\"cmd\":\"state\",\"st\":\"party\"}", &c));
    CHECK(!parse("{\"cmd\":\"state\",\"st\":1}", &c));
}

static void test_level_mic(void)
{
    ib_cmd_t c;
    CHECK(parse("{\"cmd\":\"level\",\"v\":42}", &c) && c.type == IB_CMD_LEVEL && c.level == 42);
    CHECK(parse("{\"cmd\":\"level\",\"v\":0}", &c) && c.level == 0);
    CHECK(parse("{\"cmd\":\"level\",\"v\":250}", &c) && c.level == 100);
    CHECK(!parse("{\"cmd\":\"level\"}", &c));
    CHECK(!parse("{\"cmd\":\"level\",\"v\":-3}", &c));
    CHECK(parse("{\"cmd\":\"mic\",\"on\":1}", &c) && c.type == IB_CMD_MIC && c.has_on && c.on);
    CHECK(parse("{\"cmd\":\"mic\",\"on\":0}", &c) && c.type == IB_CMD_MIC && !c.on);
    CHECK(!parse("{\"cmd\":\"mic\"}", &c));
}

static void test_keys_agent(void)
{
    ib_cmd_t c;
    CHECK(parse("{\"cmd\":\"keys\",\"up\":\"enter\",\"down\":\"esc\",\"ok\":\"mic\"}", &c));
    CHECK(c.type == IB_CMD_KEYS);
    CHECK(c.has_key_icon[IB_KEY_OK] && c.has_key_icon[IB_KEY_UP] && c.has_key_icon[IB_KEY_DOWN]);
    CHECK(c.key_icon[IB_KEY_UP] == IB_ICON_ENTER && c.key_icon[IB_KEY_DOWN] == IB_ICON_ESC &&
          c.key_icon[IB_KEY_OK] == IB_ICON_MIC);
    // 字段可选;空串与未知 id 都是 NONE(隐藏),不拒绝整条;id 区分大小写。
    CHECK(parse("{\"cmd\":\"keys\",\"down\":\"\",\"up\":\"rocket\"}", &c));
    CHECK(!c.has_key_icon[IB_KEY_OK] && c.has_key_icon[IB_KEY_DOWN] && c.key_icon[IB_KEY_DOWN] == IB_ICON_NONE);
    CHECK(c.has_key_icon[IB_KEY_UP] && c.key_icon[IB_KEY_UP] == IB_ICON_NONE);
    CHECK(parse("{\"cmd\":\"keys\",\"ok\":\"MIC\"}", &c) && c.key_icon[IB_KEY_OK] == IB_ICON_NONE);
    CHECK(parse("{\"cmd\":\"keys\"}", &c) && c.type == IB_CMD_KEYS);
    CHECK(!parse("{\"cmd\":\"keys\",\"ok\":1}", &c));

    CHECK(parse("{\"cmd\":\"agent\",\"ev\":\"done\",\"msg\":\"Claude Code\"}", &c));
    CHECK(c.type == IB_CMD_AGENT && c.has_agent_ev && c.agent_ev == IB_AGENT_DONE && c.has_msg);
    CHECK_STR(c.msg, "Claude Code");
    CHECK(parse("{\"cmd\":\"agent\",\"ev\":\"input\"}", &c) && c.agent_ev == IB_AGENT_INPUT && !c.has_msg);
    CHECK(parse("{\"cmd\":\"agent\",\"ev\":\"clear\"}", &c) && c.agent_ev == IB_AGENT_CLEAR);
    CHECK(!parse("{\"cmd\":\"agent\"}", &c));
    CHECK(!parse("{\"cmd\":\"agent\",\"ev\":\"boom\"}", &c));
    CHECK_STR(ib_agent_ev_name(IB_AGENT_INPUT), "input");
}

static void test_icons(void)
{
    // 固定 id 集合(docs/protocol.md),每个都能往返映射。
    static const char *const IDS[] = {
        "enter", "esc", "undo", "stab", "tab", "send", "stop", "cancel", "check", "repeat",
        "mode", "apps", "mic", "translate", "hide", "up", "down", "play", "open",
    };
    CHECK((int)(sizeof(IDS) / sizeof(IDS[0])) == IB_ICON_COUNT - 1);
    for (size_t i = 0; i < sizeof(IDS) / sizeof(IDS[0]); i++) {
        ib_icon_t icon = ib_icon_from_id(IDS[i]);
        CHECK(icon != IB_ICON_NONE);
        CHECK_STR(ib_icon_id(icon), IDS[i]);
    }
    CHECK(ib_icon_from_id(NULL) == IB_ICON_NONE);
    CHECK(ib_icon_from_id("") == IB_ICON_NONE);
    CHECK(ib_icon_from_id("enter ") == IB_ICON_NONE);
    CHECK_STR(ib_icon_id(IB_ICON_NONE), "");
    CHECK_STR(ib_icon_id(IB_ICON_COUNT), "?");
}

static void test_list(void)
{
    ib_cmd_t c;
    CHECK(parse("{\"cmd\":\"state\",\"st\":\"list\",\"mode\":\"dict\"}", &c) && c.state == IB_ST_LIST);
    CHECK_STR(ib_state_name(IB_ST_LIST), "list");

    CHECK(parse("{\"cmd\":\"list\",\"title\":\"SWITCH APP\",\"sel\":2,\"n\":7,\"top\":0,"
                "\"i0\":\"Ghostty\",\"i1\":\"Chrome\",\"i2\":\"Xcode\",\"i3\":\"Finder\",\"i4\":\"Mail\",\"i5\":\"Notes\"}",
                &c));
    CHECK(c.type == IB_CMD_LIST && c.list_n == 7 && c.list_sel == 2 && c.list_top == 0 && c.list_rows == 6);
    CHECK_STR(c.list_title, "SWITCH APP");
    CHECK_STR(c.list_item[0], "Ghostty");
    CHECK_STR(c.list_item[5], "Notes");

    // 超过 6 行:i6 以后作为未知字段忽略。
    CHECK(parse("{\"cmd\":\"list\",\"sel\":0,\"n\":9,\"i0\":\"a\",\"i6\":\"g\",\"i7\":\"h\",\"i10\":\"x\"}", &c));
    CHECK(c.list_rows == 1 && c.list_title[0] == '\0' && c.list_top == 0);
    // 行可以缺(中间为空串),项名超长截断、非 ASCII 折叠。
    CHECK(parse("{\"cmd\":\"list\",\"sel\":3,\"n\":5,\"top\":2,\"i2\":\"ABCDEFGHIJKLMNOPQRSTUVWXYZ\",\"i0\":\"\xE5\xBE\xAE\xE4\xBF\xA1\"}", &c));
    CHECK(c.list_rows == 3 && c.list_item[1][0] == '\0' && c.list_top == 2);
    CHECK_STR(c.list_item[2], "ABCDEFGHIJKLMNOPQRSTUVW");
    CHECK_STR(c.list_item[0], "??");
    // 空列表:n=0,sel 不检查。
    CHECK(parse("{\"cmd\":\"list\",\"title\":\"EMPTY\",\"sel\":0,\"n\":0}", &c) && c.list_n == 0 && c.list_rows == 0);
    // 必填字段缺失、越界、类型错误 → 整条丢弃。
    CHECK(!parse("{\"cmd\":\"list\",\"n\":3}", &c));
    CHECK(!parse("{\"cmd\":\"list\",\"sel\":1}", &c));
    CHECK(!parse("{\"cmd\":\"list\",\"sel\":3,\"n\":3}", &c));
    CHECK(!parse("{\"cmd\":\"list\",\"sel\":0,\"n\":3,\"top\":3}", &c));
    CHECK(!parse("{\"cmd\":\"list\",\"sel\":0,\"n\":65536}", &c));
    CHECK(!parse("{\"cmd\":\"list\",\"sel\":\"1\",\"n\":3}", &c));
    CHECK(!parse("{\"cmd\":\"list\",\"sel\":0,\"n\":3,\"i0\":1}", &c));
    CHECK(!parse("{\"cmd\":\"list\",\"sel\":0,\"n\":3,\"title\":7}", &c));
}

typedef struct {
    int count;
    char last[IB_LINE_MAX];
} lines_t;

static void on_line(const char *line, size_t len, void *user)
{
    lines_t *l = user;
    CHECK(strlen(line) == len);
    memcpy(l->last, line, len + 1);
    l->count++;
}

static void feed(ib_line_t *lf, const char *s, lines_t *out)
{
    ib_line_feed(lf, (const uint8_t *)s, strlen(s), on_line, out);
}

static void test_line_framing(void)
{
    ib_line_t lf;
    lines_t out = { 0 };
    ib_line_init(&lf);

    feed(&lf, "{\"cmd\":", &out);
    CHECK(out.count == 0);
    feed(&lf, "\"ping\"}\r\n\n\n{\"cmd\":\"bye\"}\n{\"cmd\"", &out);
    CHECK(out.count == 2);
    CHECK_STR(out.last, "{\"cmd\":\"bye\"}");
    feed(&lf, ":\"hello\"}\n", &out);
    CHECK(out.count == 3);
    CHECK_STR(out.last, "{\"cmd\":\"hello\"}");

    // 超长行整行丢弃,下一行正常。
    static char longline[IB_LINE_MAX + 100];
    memset(longline, 'a', sizeof(longline) - 1);
    longline[sizeof(longline) - 1] = '\0';
    feed(&lf, longline, &out);
    feed(&lf, "tail\n{\"cmd\":\"ping\"}\n", &out);
    CHECK(out.count == 4);
    CHECK_STR(out.last, "{\"cmd\":\"ping\"}");

    // 正好 511 字节的行可以收下。
    static char max_line[IB_LINE_MAX + 1];
    memset(max_line, 'b', IB_LINE_MAX - 1);
    max_line[IB_LINE_MAX - 1] = '\n';
    max_line[IB_LINE_MAX] = '\0';
    feed(&lf, max_line, &out);
    CHECK(out.count == 5 && strlen(out.last) == IB_LINE_MAX - 1);
}

int main(void)
{
    test_format();
    test_simple();
    test_config();
    test_state();
    test_level_mic();
    test_keys_agent();
    test_list();
    test_icons();
    test_line_framing();
    TEST_DONE("test_ib_protocol");
}
