// main/ib_ble.c: InputBetter BLE 链路(NimBLE GATT 外设)。
//
// GATT(与 docs/protocol.md 一致):
//   Service   B5E10001-5A6C-4E8B-9F2D-7C3A1E0B4D21   Primary,UUID 放在广播包
//   Events    B5E10002-...   Notify                   设备 → Mac,JSON 行(按 MTU 分片)
//   Commands  B5E10003-...   Write / Write No Rsp     Mac → 设备,JSON 行(可能半行)
//   Audio In  B5E10004-...   Notify                   设备 → Mac,二进制帧(每帧 1 块 ADPCM,170 字节)
// 单连接;断开后立即恢复广播。开机、断开、USB 拔线后先以 20 ms 间隔广播 30 秒,之后 211.25 ms。
#include "ib_ble.h"

#include "ib_protocol.h"

#include "esp_check.h"
#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include <string.h>

static const char *TAG = "ib_ble";
static const char *DEVICE_NAME = "InputBetter";

#define ADV_FAST_ITVL BLE_GAP_ADV_ITVL_MS(20)
#define ADV_FAST_MS   30000
#define ADV_SLOW_ITVL 338       // 211.25 ms(单位 0.625 ms)

// NimBLE 的 128 位 UUID 按小端书写(字符串字节倒序)。四个 UUID 只有第一段末字节不同。
#define IB_UUID128(b)                                                      \
    BLE_UUID128_INIT(0x21, 0x4D, 0x0B, 0x1E, 0x3A, 0x7C, 0x2D, 0x9F,       \
                     0x8B, 0x4E, 0x6C, 0x5A, (b), 0x00, 0xE1, 0xB5)

static const ble_uuid128_t s_service_uuid = IB_UUID128(0x01);
static const ble_uuid128_t s_events_uuid = IB_UUID128(0x02);
static const ble_uuid128_t s_commands_uuid = IB_UUID128(0x03);
static const ble_uuid128_t s_audio_in_uuid = IB_UUID128(0x04);

static ib_ble_line_cb_t s_on_line;
static ib_ble_link_cb_t s_on_link;
static uint16_t s_events_handle;
static uint16_t s_audio_handle;
static uint8_t s_own_addr_type;
static bool s_started;

// host 任务写,其它任务读;读到过期值最多让一次 Notify 失败。
static volatile uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static volatile bool s_subscribed;
static volatile bool s_audio_subscribed;
static volatile bool s_audio_mode;

static ib_line_t s_rx_line;     // 只在 host 任务中访问
static struct ble_npl_event s_boost_event;
static struct ble_npl_event s_params_event;

static int gap_event(struct ble_gap_event *event, void *arg);

static void dispatch(const char *line, size_t len, void *user)
{
    (void)user;
    s_on_line(line, len);
}

static int notify_only_access(uint16_t conn_handle, uint16_t attr_handle, struct ble_gatt_access_ctxt *ctxt,
                              void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)ctxt;
    (void)arg;
    return BLE_ATT_ERR_READ_NOT_PERMITTED;
}

static int commands_access(uint16_t conn_handle, uint16_t attr_handle, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;
    uint8_t buf[IB_LINE_MAX];
    uint16_t len = 0;
    if (OS_MBUF_PKTLEN(ctxt->om) > sizeof(buf)) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf), &len) != 0) return BLE_ATT_ERR_UNLIKELY;
    ib_line_feed(&s_rx_line, buf, len, dispatch, NULL);
    return 0;
}

static const struct ble_gatt_svc_def s_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_service_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_events_uuid.u,
                .access_cb = notify_only_access,
                .val_handle = &s_events_handle,
                .flags = BLE_GATT_CHR_F_NOTIFY,
            },
            {
                .uuid = &s_commands_uuid.u,
                .access_cb = commands_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = &s_audio_in_uuid.u,
                .access_cb = notify_only_access,
                .val_handle = &s_audio_handle,
                .flags = BLE_GATT_CHR_F_NOTIFY,
            },
            { 0 },
        },
    },
    { 0 },
};

static void start_advertising(bool fast)
{
    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = &s_service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv fields failed: %d", rc);
        return;
    }
    // 名称放扫描响应:与 128 位 UUID 一起放主广播包会超过 31 字节。
    struct ble_hs_adv_fields rsp = { 0 };
    rsp.name = (const uint8_t *)DEVICE_NAME;
    rsp.name_len = (uint8_t)strlen(DEVICE_NAME);
    rsp.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) {
        ESP_LOGE(TAG, "scan rsp failed: %d", rc);
        return;
    }
    struct ble_gap_adv_params params = { 0 };
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = fast ? ADV_FAST_ITVL : ADV_SLOW_ITVL;
    params.itvl_max = params.itvl_min;
    rc = ble_gap_adv_start(s_own_addr_type, NULL, fast ? ADV_FAST_MS : BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) ESP_LOGE(TAG, "adv start failed: %d", rc);
}

static void request_conn_params(uint16_t conn)
{
    // Apple 配件设计指南:间隔 15~30 ms、监督超时 4 s;平时从机延迟 4 省电,音频期间 0。
    const struct ble_gap_upd_params p = {
        .itvl_min = BLE_GAP_CONN_ITVL_MS(15),
        .itvl_max = BLE_GAP_CONN_ITVL_MS(30),
        .latency = s_audio_mode ? 0 : 4,
        .supervision_timeout = BLE_GAP_SUPERVISION_TIMEOUT_MS(4000),
        .min_ce_len = 0,
        .max_ce_len = 0,
    };
    int rc = ble_gap_update_params(conn, &p);
    if (rc != 0) ESP_LOGW(TAG, "conn params request failed: %d", rc);
}

static void set_subscribed(bool on)
{
    if (on == s_subscribed) return;
    s_subscribed = on;
    s_on_link(on);
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn = event->connect.conn_handle;
            ib_line_init(&s_rx_line);
        } else {
            start_advertising(true);
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_audio_subscribed = false;
        set_subscribed(false);
        start_advertising(true);
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s_events_handle) {
            set_subscribed(event->subscribe.cur_notify);
            if (event->subscribe.cur_notify) request_conn_params(event->subscribe.conn_handle);
        } else if (event->subscribe.attr_handle == s_audio_handle) {
            s_audio_subscribed = event->subscribe.cur_notify;
        }
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        if (s_conn == BLE_HS_CONN_HANDLE_NONE) start_advertising(false);
        break;
    default:
        break;
    }
    return 0;
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0) rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "address setup failed: %d", rc);
        return;
    }
    start_advertising(true);
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "host reset: %d", reason);
    s_conn = BLE_HS_CONN_HANDLE_NONE;
    s_audio_subscribed = false;
    set_subscribed(false);
}

static void on_boost(struct ble_npl_event *ev)
{
    (void)ev;
    if (!ble_hs_synced() || s_conn != BLE_HS_CONN_HANDLE_NONE) return;
    ble_gap_adv_stop();
    start_advertising(true);
}

static void on_params(struct ble_npl_event *ev)
{
    (void)ev;
    uint16_t conn = s_conn;
    if (ble_hs_synced() && conn != BLE_HS_CONN_HANDLE_NONE) request_conn_params(conn);
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t ib_ble_start(ib_ble_line_cb_t on_line, ib_ble_link_cb_t on_link)
{
    s_on_line = on_line;
    s_on_link = on_link;
    ib_line_init(&s_rx_line);

    ESP_RETURN_ON_ERROR(nimble_port_init(), TAG, "nimble init failed");
    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_gatts_count_cfg(s_services);
    if (rc == 0) rc = ble_gatts_add_svcs(s_services);
    if (rc == 0) rc = ble_svc_gap_device_name_set(DEVICE_NAME);
    if (rc != 0) {
        ESP_LOGE(TAG, "gatt setup failed: %d", rc);
        nimble_port_deinit();
        return ESP_FAIL;
    }
    ble_npl_event_init(&s_boost_event, on_boost, NULL);
    ble_npl_event_init(&s_params_event, on_params, NULL);
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    nimble_port_freertos_init(host_task);
    s_started = true;
    return ESP_OK;
}

void ib_ble_send(const char *data, size_t len)
{
    uint16_t conn = s_conn;
    if (!s_started || len == 0 || !s_subscribed || conn == BLE_HS_CONN_HANDLE_NONE) return;
    uint16_t mtu = ble_att_mtu(conn);
    size_t chunk = mtu > 3 ? (size_t)mtu - 3 : 20;
    for (size_t off = 0; off < len; off += chunk) {
        size_t n = len - off < chunk ? len - off : chunk;
        struct os_mbuf *om = ble_hs_mbuf_from_flat(data + off, (uint16_t)n);
        if (!om) return;
        // 无论成功与否 om 都由协议栈释放。
        if (ble_gatts_notify_custom(conn, s_events_handle, om) != 0) return;
    }
}

void ib_ble_send_audio(const uint8_t *frame, size_t len)
{
    uint16_t conn = s_conn;
    if (!s_started || len == 0 || !s_audio_subscribed || conn == BLE_HS_CONN_HANDLE_NONE) return;
    uint16_t mtu = ble_att_mtu(conn);
    if (mtu < 3 || len > (size_t)mtu - 3) return;     // 帧不能分片,MTU 不够就丢
    struct os_mbuf *om = ble_hs_mbuf_from_flat(frame, (uint16_t)len);
    if (!om) return;
    ble_gatts_notify_custom(conn, s_audio_handle, om);
}

void ib_ble_set_audio_mode(bool on)
{
    if (!s_started || s_audio_mode == on) return;
    s_audio_mode = on;
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &s_params_event);
}

void ib_ble_boost_advertising(void)
{
    if (!s_started) return;
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &s_boost_event);
}

uint16_t ib_ble_mtu(void)
{
    uint16_t conn = s_conn;
    return (s_started && conn != BLE_HS_CONN_HANDLE_NONE) ? ble_att_mtu(conn) : 0;
}
