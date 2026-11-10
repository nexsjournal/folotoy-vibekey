// Wi-Fi 与 TLS 分开运行：配置任务管理网络；服务器任务独占 TLS 会话，音频任务只投递发送队列。
#include "ib_wifi.h"
#include "ib_protocol.h"
#include "ib_usb.h"
#include "ib_wifi_store.h"
#include "cJSON.h"
#include "esp_attr.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_tls.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "mdns.h"
#include "nvs.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#define WIFI_PORT 8765
#define IP_READY BIT0
#define NVS_NAMESPACE "ib_wifi"
#define NVS_STORE_KEY "networks"
#define NVS_LEGACY_KEY "config"
#define NVS_BLE_MODE_KEY "ble_mode"
// 最大上行音频帧 334 字节，JSON 回复也小于 512；无需为每个队列项预留 1 KB。
#define PACKET_MAX 512
#define WIFI_STALL_US (8 * INT64_C(1000000))
#define WIFI_HANDSHAKE_TIMEOUT_US (6 * INT64_C(1000000))
#define BLE_FALLBACK_MAGIC 0x56425331u     // "VBS1"
#define BLE_FALLBACK_MODE 1
#define BLE_MANUAL_MODE 2
static const char *TAG = "ib_wifi";
typedef struct { size_t len; uint8_t bytes[PACKET_MAX]; } packet_t;
static QueueHandle_t s_config_queue, s_control_tx, s_audio_tx;
static EventGroupHandle_t s_events;
static ib_wifi_line_cb_t s_line;
static ib_wifi_link_cb_t s_link;
static ib_wifi_network_t s_config;
static ib_wifi_store_t s_store;
static bool s_store_loaded;
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static volatile uint32_t s_generation;
static volatile bool s_configured, s_session;
static volatile bool s_available;
static char s_stage[24] = "unconfigured";
static esp_netif_t *s_netif;
static volatile int s_handshake_fd = -1;
static volatile int64_t s_handshake_started;
static esp_timer_handle_t s_handshake_timer;
static esp_timer_handle_t s_reconnect_timer;
static uint32_t s_reconnect_delay_ms = 1000;
// RTC_DATA_ATTR 在软件重启时会由启动代码清零；这里必须用 NOINIT，靠 magic 排除上电随机值。
RTC_NOINIT_ATTR static uint32_t s_boot_mode_magic;
RTC_NOINIT_ATTR static uint8_t s_boot_mode;

static bool save_store(const ib_wifi_store_t *store)
{
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs) != ESP_OK) return false;
    bool ok = ib_wifi_store_valid(store)
        && nvs_set_blob(nvs, NVS_STORE_KEY, store, sizeof(*store)) == ESP_OK
        && nvs_commit(nvs) == ESP_OK;
    nvs_close(nvs);
    return ok;
}

static bool load_store(ib_wifi_store_t *store)
{
    ib_wifi_store_init(store);
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs) != ESP_OK) return false;

    size_t size = sizeof(*store);
    if (nvs_get_blob(nvs, NVS_STORE_KEY, store, &size) == ESP_OK
        && size == sizeof(*store) && ib_wifi_store_valid(store)) {
        nvs_close(nvs);
        return true;
    }

    ib_wifi_legacy_t legacy;
    memset(&legacy, 0, sizeof(legacy));
    size = sizeof(legacy);
    if (nvs_get_blob(nvs, NVS_LEGACY_KEY, &legacy, &size) == ESP_OK
        && ib_wifi_store_from_legacy(store, &legacy, size)) {
        // 先提交新结构，再删除旧键；迁移过程中掉电也能在下次启动重试。
        if (nvs_set_blob(nvs, NVS_STORE_KEY, store, sizeof(*store)) == ESP_OK
            && nvs_commit(nvs) == ESP_OK) {
            nvs_erase_key(nvs, NVS_LEGACY_KEY);
            nvs_commit(nvs);
        }
    } else {
        ib_wifi_store_init(store);
    }
    memset(&legacy, 0, sizeof(legacy));
    nvs_close(nvs);
    return true;
}

static ib_wifi_store_t store_snapshot(void)
{
    ib_wifi_store_t store;
    bool loaded;
    portENTER_CRITICAL(&s_lock);
    loaded = s_store_loaded;
    store = s_store;
    portEXIT_CRITICAL(&s_lock);
    if (!loaded) {
        ib_wifi_store_t fresh;
        if (!load_store(&fresh)) {
            ib_wifi_store_init(&fresh);
            return fresh;
        }
        portENTER_CRITICAL(&s_lock);
        if (!s_store_loaded) { s_store = fresh; s_store_loaded = true; }
        else fresh = s_store;
        portEXIT_CRITICAL(&s_lock);
        store = fresh;
    }
    return store;
}

static void replace_store(const ib_wifi_store_t *store)
{
    portENTER_CRITICAL(&s_lock);
    s_store = *store;
    s_store_loaded = true;
    portEXIT_CRITICAL(&s_lock);
}

static bool active_network(const ib_wifi_store_t *store, ib_wifi_network_t *network)
{
    if (!ib_wifi_store_valid(store) || !store->count || store->active >= store->count) return false;
    *network = store->networks[store->active];
    return true;
}

bool ib_wifi_is_configured(void)
{
    return store_snapshot().count > 0;
}

bool ib_wifi_is_ready(void)
{
    return s_available && s_events && (xEventGroupGetBits(s_events) & IP_READY);
}

bool ib_wifi_ble_fallback_requested(void)
{
    if (s_boot_mode_magic == BLE_FALLBACK_MAGIC) {
        return s_boot_mode == BLE_FALLBACK_MODE || s_boot_mode == BLE_MANUAL_MODE;
    }
    nvs_handle_t nvs;
    uint8_t mode = 0;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs) != ESP_OK) return false;
    bool requested = nvs_get_u8(nvs, NVS_BLE_MODE_KEY, &mode) == ESP_OK
        && (mode == BLE_FALLBACK_MODE || mode == BLE_MANUAL_MODE);
    nvs_close(nvs);
    return requested;
}

bool ib_wifi_ble_manual_requested(void)
{
    if (s_boot_mode_magic == BLE_FALLBACK_MAGIC) return s_boot_mode == BLE_MANUAL_MODE;
    nvs_handle_t nvs;
    uint8_t mode = 0;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs) != ESP_OK) return false;
    bool requested = nvs_get_u8(nvs, NVS_BLE_MODE_KEY, &mode) == ESP_OK && mode == BLE_MANUAL_MODE;
    nvs_close(nvs);
    return requested;
}

static void request_boot_mode(uint8_t mode)
{
    s_boot_mode = mode;
    s_boot_mode_magic = BLE_FALLBACK_MAGIC;
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs) == ESP_OK) {
        if (nvs_set_u8(nvs, NVS_BLE_MODE_KEY, mode) == ESP_OK) nvs_commit(nvs);
        nvs_close(nvs);
    }
}

void ib_wifi_request_ble_fallback(void) { request_boot_mode(BLE_FALLBACK_MODE); }

void ib_wifi_request_bluetooth(void) { request_boot_mode(BLE_MANUAL_MODE); }

void ib_wifi_clear_ble_fallback(void)
{
    s_boot_mode_magic = 0;
    s_boot_mode = 0;
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs) == ESP_OK) {
        esp_err_t error = nvs_erase_key(nvs, NVS_BLE_MODE_KEY);
        if (error == ESP_OK) nvs_commit(nvs);
        nvs_close(nvs);
    }
}

static void status(const char *stage, const char *ip)
{
    char out[512], host[32], ssid[33];
    portENTER_CRITICAL(&s_lock);
    snprintf(s_stage, sizeof(s_stage), "%s", stage);
    memcpy(host, s_config.host, sizeof(host));
    memcpy(ssid, s_config.ssid, sizeof(ssid));
    ib_wifi_store_t store = s_store;
    portEXIT_CRITICAL(&s_lock);
    cJSON *root = cJSON_CreateObject();
    if (!root) return;
    cJSON_AddStringToObject(root, "t", "wifi");
    cJSON_AddStringToObject(root, "stage", stage);
    cJSON_AddStringToObject(root, "host", host);
    cJSON_AddStringToObject(root, "ssid", ssid);
    cJSON_AddStringToObject(root, "ip", ip ? ip : "");
    cJSON_AddNumberToObject(root, "active", store.count ? store.active : 0);
    cJSON_AddNumberToObject(root, "count", store.count);
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) cJSON_AddNumberToObject(root, "rssi", ap.rssi);
    cJSON_AddNumberToObject(root, "heap", esp_get_free_heap_size());
    if (cJSON_PrintPreallocated(root, out, sizeof(out) - 1, false)) {
        size_t n = strlen(out); out[n++] = '\n'; ib_usb_send(out, n);
    }
    cJSON_Delete(root);
}

static void send_network_list(void)
{
    ib_wifi_store_t store = store_snapshot();
    static char out[1536];
    cJSON *root = cJSON_CreateObject();
    if (!root) return;
    cJSON_AddStringToObject(root, "t", "wifi");
    cJSON_AddStringToObject(root, "stage", "list");
    cJSON_AddNumberToObject(root, "count", store.count);
    cJSON_AddNumberToObject(root, "active", store.count ? store.active : 0);
    cJSON *networks = cJSON_AddArrayToObject(root, "networks");
    for (uint8_t i = 0; networks && i < store.count; i++) {
        cJSON *item = cJSON_CreateObject();
        if (!item) break;
        cJSON_AddStringToObject(item, "ssid", store.networks[i].ssid);
        cJSON_AddStringToObject(item, "host", store.networks[i].host);
        cJSON_AddNumberToObject(item, "active", i == store.active ? 1 : 0);
        cJSON_AddItemToArray(networks, item);
    }
    if (cJSON_PrintPreallocated(root, out, sizeof(out) - 1, false)) {
        size_t n = strlen(out); out[n++] = '\n'; ib_usb_send(out, n);
    }
    cJSON_Delete(root);
}

void ib_wifi_report_status(void)
{
    char stage[24], ip[16] = "";
    portENTER_CRITICAL(&s_lock); memcpy(stage, s_stage, sizeof(stage)); portEXIT_CRITICAL(&s_lock);
    if (!ib_wifi_is_configured()) strcpy(stage, "unconfigured");
    else if (!s_available) strcpy(stage, "network_error");
    if (s_netif && s_available) {
        esp_netif_ip_info_t info;
        if (esp_netif_get_ip_info(s_netif, &info) == ESP_OK && info.ip.addr) {
            snprintf(ip, sizeof(ip), IPSTR, IP2STR(&info.ip));
        }
    }
    status(stage, ip);
}

static void reconnect_timer_cb(void *arg)
{
    (void)arg;
    if (s_configured) esp_wifi_connect();
}

static void network_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) esp_wifi_connect();
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        xEventGroupClearBits(s_events, IP_READY);
        // IP 可能很快恢复，仍须关闭上一轮关联留下的 TLS 会话。
        portENTER_CRITICAL(&s_lock); s_generation++; portEXIT_CRITICAL(&s_lock);
        const wifi_event_sta_disconnected_t *event = data;
        wifi_ap_record_t ap;
        int rssi = esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : 0;
        ESP_LOGW(TAG, "STA disconnected: reason=%u rssi=%d", (unsigned)event->reason, rssi);
        const char *stage = (event->reason == WIFI_REASON_AUTH_FAIL || event->reason == WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT)
            ? "auth_error" : event->reason == WIFI_REASON_NO_AP_FOUND ? "not_found" : "connecting";
        status(stage, NULL);
        // 热点或信号抖动时不要立刻重连打满驱动；1→2→4→8 秒退避，入网后复位。
        if (s_configured && s_reconnect_timer) {
            esp_timer_stop(s_reconnect_timer);
            uint32_t delay_ms = s_reconnect_delay_ms;
            s_reconnect_delay_ms = delay_ms < 8000 ? delay_ms * 2 : 8000;
            esp_timer_start_once(s_reconnect_timer, (uint64_t)delay_ms * 1000);
        }
    }
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = data;
        char ip[16]; snprintf(ip, sizeof(ip), IPSTR, IP2STR(&event->ip_info.ip));
        s_reconnect_delay_ms = 1000;
        if (s_reconnect_timer) esp_timer_stop(s_reconnect_timer);
        xEventGroupSetBits(s_events, IP_READY);
        status("ready", ip);
    }
}

static void line_received(const char *line, size_t len, void *user)
{
    (void)user;
    if (s_line) s_line(line, len);
}

// 按键、心跳和录音分开排队。录音来不及发时可丢帧，不能挤掉松键或心跳。
static void enqueue(QueueHandle_t queue, const uint8_t *data, size_t len)
{
    if (!s_session || !queue || len == 0 || len > PACKET_MAX) return;
    packet_t packet = { .len = len };
    memcpy(packet.bytes, data, len);
    xQueueSend(queue, &packet, 0);
}

void ib_wifi_send(const uint8_t *data, size_t len) { enqueue(s_control_tx, data, len); }
void ib_wifi_send_audio(const uint8_t *data, size_t len) { enqueue(s_audio_tx, data, len); }

// 单个任务拥有 TLS。暂时不可读写时保留待发帧及偏移，直到同一次 TLS 写入完成。
static void run_session(esp_tls_t *tls, int fd, uint32_t generation)
{
    ib_line_t lines;
    ib_line_init(&lines);
    uint8_t input[512];
    packet_t outgoing;
    size_t offset = 0;
    bool pending = false;
    int write_wait = 0;
    bool read_wait_write = false;
    int64_t write_since = 0, read_since = 0;

    while (generation == s_generation && (xEventGroupGetBits(s_events) & IP_READY)) {
        int64_t now = esp_timer_get_time();
        bool write_stalled = write_since && now - write_since >= WIFI_STALL_US;
        bool read_stalled = read_since && now - read_since >= WIFI_STALL_US;
        if (write_stalled || read_stalled) {
            ESP_LOGW(TAG, "TLS %s stalled, reconnecting (heap=%" PRIu32 ")",
                     write_stalled ? "send" : "receive", esp_get_free_heap_size());
            return;
        }
        if (!pending && !read_wait_write) {
            pending = xQueueReceive(s_control_tx, &outgoing, 0) == pdTRUE
                   || xQueueReceive(s_audio_tx, &outgoing, 0) == pdTRUE;
            offset = 0;
            if (pending) write_since = now;
        }

        fd_set reads, writes;
        FD_ZERO(&reads); FD_ZERO(&writes);
        if (!read_wait_write && write_wait != ESP_TLS_ERR_SSL_WANT_WRITE) FD_SET(fd, &reads);
        if (read_wait_write || (pending && write_wait != ESP_TLS_ERR_SSL_WANT_READ)) FD_SET(fd, &writes);
        bool buffered = !read_wait_write && !write_wait && esp_tls_get_bytes_avail(tls) > 0;
        struct timeval wait = { .tv_usec = buffered ? 0 : 5000 };
        int ready = select(fd + 1, &reads, &writes, NULL, &wait);
        if (ready < 0) {
            if (errno == EINTR) continue;
            ESP_LOGW(TAG, "TLS select failed: errno=%d", errno);
            return;
        }
        bool readable = FD_ISSET(fd, &reads);
        bool writable = FD_ISSET(fd, &writes);

        if (!write_wait && (read_wait_write ? writable : readable || buffered)) {
            int n = esp_tls_conn_read(tls, input, sizeof(input));
            read_wait_write = n == ESP_TLS_ERR_SSL_WANT_WRITE;
            if (read_wait_write) {
                if (!read_since) read_since = now;
                continue;
            }
            read_since = 0;
            if (n > 0) ib_line_feed(&lines, input, n, line_received, NULL);
            else if (n != ESP_TLS_ERR_SSL_WANT_READ) {
                if (n < 0) ESP_LOGW(TAG, "TLS receive failed: %d", n);
                return;
            }
        }

        if (pending && (write_wait == ESP_TLS_ERR_SSL_WANT_READ ? readable : writable)) {
            int n = esp_tls_conn_write(tls, outgoing.bytes + offset, outgoing.len - offset);
            if (n > 0) {
                offset += (size_t)n;
                pending = offset < outgoing.len;
                write_wait = 0;
                write_since = pending ? now : 0;
            } else if (n == ESP_TLS_ERR_SSL_WANT_READ || n == ESP_TLS_ERR_SSL_WANT_WRITE) {
                write_wait = n;
            } else {
                ESP_LOGW(TAG, "TLS send failed: %d (heap=%" PRIu32 ")", n, esp_get_free_heap_size());
                return;
            }
        }
    }
}

static void server_task(void *arg)
{
    (void)arg;
    int listener = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    if (listener < 0) { status("server_error", NULL); vTaskDelete(NULL); return; }
    int reuse = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(WIFI_PORT), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 2) != 0) {
        close(listener); status("server_error", NULL); vTaskDelete(NULL); return;
    }
    for (;;) {
        xEventGroupWaitBits(s_events, IP_READY, pdFALSE, pdTRUE, portMAX_DELAY);
        int socket_fd = accept(listener, NULL, NULL);
        if (socket_fd < 0) { vTaskDelay(pdMS_TO_TICKS(100)); continue; }
        struct timeval timeout = { .tv_sec = 4, .tv_usec = 0 };
        setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        int one = 1;
        setsockopt(socket_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        ib_wifi_network_t config;
        portENTER_CRITICAL(&s_lock); config = s_config; uint32_t generation = s_generation; portEXIT_CRITICAL(&s_lock);
        psk_hint_key_t psk = { .key = config.key, .key_size = sizeof(config.key), .hint = "folobutton" };
        esp_tls_cfg_server_t tls_config = {
            .psk_hint_key = &psk,
            .tls_handshake_timeout_ms = 5000,
        };
        esp_tls_t *tls = esp_tls_init();
        portENTER_CRITICAL(&s_lock);
        s_handshake_fd = socket_fd;
        s_handshake_started = esp_timer_get_time();
        portEXIT_CRITICAL(&s_lock);
        if (s_handshake_timer) esp_timer_start_once(s_handshake_timer, WIFI_HANDSHAKE_TIMEOUT_US);
        int handshake = tls ? esp_tls_server_session_create(&tls_config, socket_fd, tls) : -1;
        if (s_handshake_timer) esp_timer_stop(s_handshake_timer);
        portENTER_CRITICAL(&s_lock);
        s_handshake_fd = -1;
        s_handshake_started = 0;
        portEXIT_CRITICAL(&s_lock);
        if (handshake != 0) {
            ESP_LOGW(TAG, "TLS handshake failed: %d", handshake);
            if (tls) esp_tls_server_session_delete(tls); else close(socket_fd);
            memset(&config, 0, sizeof(config)); continue;
        }
        int flags = fcntl(socket_fd, F_GETFL, 0);
        if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            ESP_LOGW(TAG, "Cannot set TLS socket nonblocking: errno=%d", errno);
            esp_tls_server_session_delete(tls);
            memset(&config, 0, sizeof(config)); continue;
        }
        xQueueReset(s_control_tx);
        xQueueReset(s_audio_tx);
        s_session = true;
        if (s_link) s_link(true);
        run_session(tls, socket_fd, generation);
        s_session = false;
        if (s_link) s_link(false);
        esp_tls_server_session_delete(tls);
        memset(&config, 0, sizeof(config));
    }
}

static void handshake_timeout(void *arg)
{
    (void)arg;
    int fd;
    int64_t started;
    portENTER_CRITICAL(&s_lock);
    fd = s_handshake_fd;
    started = s_handshake_started;
    portEXIT_CRITICAL(&s_lock);
    if (fd >= 0 && started > 0) {
        ESP_LOGW(TAG, "TLS handshake timeout, closing fd=%d", fd);
        shutdown(fd, SHUT_RDWR);
    }
}

static void config_task(void *arg)
{
    (void)arg;
    ib_wifi_network_t next;
    for (;;) {
        if (xQueueReceive(s_config_queue, &next, portMAX_DELAY) != pdTRUE) continue;
        s_configured = false;
        if (s_reconnect_timer) esp_timer_stop(s_reconnect_timer);
        s_reconnect_delay_ms = 1000;
        xEventGroupClearBits(s_events, IP_READY);
        esp_wifi_disconnect();
        esp_wifi_stop();
        portENTER_CRITICAL(&s_lock); s_config = next; s_generation++; portEXIT_CRITICAL(&s_lock);
        wifi_config_t wifi = { 0 };
        memcpy(wifi.sta.ssid, next.ssid, strlen(next.ssid));
        memcpy(wifi.sta.password, next.password, strlen(next.password));
        wifi.sta.pmf_cfg.capable = true;
        esp_netif_set_hostname(s_netif, next.host);
        mdns_hostname_set(next.host);
        esp_err_t error = esp_wifi_set_config(WIFI_IF_STA, &wifi);
        memset(&wifi, 0, sizeof(wifi)); memset(&next, 0, sizeof(next));
        if (error == ESP_OK) {
            s_configured = true;
            status("connecting", NULL);
            if (esp_wifi_start() != ESP_OK) status("network_error", NULL);
        } else { status("network_error", NULL); }
    }
}

static int hex_digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool ib_wifi_handle_control_line(const char *line, size_t len, bool allow_provisioning)
{
    // Wi-Fi 凭据保留 UTF-8，不经过屏幕协议的 ASCII 文本归一化。
    cJSON *root = cJSON_ParseWithLength(line, len);
    if (!root) return false;
    const cJSON *command = cJSON_GetObjectItemCaseSensitive(root, "cmd");
    if (!cJSON_IsString(command) || strcmp(command->valuestring, "wifi") != 0) { cJSON_Delete(root); return false; }
    const cJSON *op = cJSON_GetObjectItemCaseSensitive(root, "op");
    const cJSON *clear = cJSON_GetObjectItemCaseSensitive(root, "clear");
    const char *operation = cJSON_IsString(op) ? op->valuestring : "add";
    if ((cJSON_IsNumber(clear) && clear->valueint == 1) || strcmp(operation, "clear") == 0) {
        if (!allow_provisioning) { cJSON_Delete(root); return false; }
        nvs_handle_t nvs;
        bool cleared = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs) == ESP_OK;
        if (cleared) {
            esp_err_t error = nvs_erase_key(nvs, NVS_STORE_KEY);
            if (error != ESP_OK && error != ESP_ERR_NVS_NOT_FOUND) cleared = false;
            error = nvs_erase_key(nvs, NVS_LEGACY_KEY);
            if (error != ESP_OK && error != ESP_ERR_NVS_NOT_FOUND) cleared = false;
            cleared = cleared && nvs_commit(nvs) == ESP_OK;
            nvs_close(nvs);
        }
        ib_wifi_store_t empty;
        ib_wifi_store_init(&empty);
        replace_store(&empty);
        portENTER_CRITICAL(&s_lock);
        memset(&s_config, 0, sizeof(s_config));
        portEXIT_CRITICAL(&s_lock);
        cJSON_Delete(root);
        status(cleared ? "unconfigured" : "config_error", NULL);
        if (cleared) { vTaskDelay(pdMS_TO_TICKS(150)); esp_restart(); }
        return true;
    }

    if (strcmp(operation, "list") == 0) {
        if (!allow_provisioning) { cJSON_Delete(root); return false; }
        send_network_list();
        cJSON_Delete(root);
        return true;
    }

    // 不删除配网记录，只让设备重启到 BLE 单栈；之后仍可从设备菜单或 App 切回 Wi-Fi。
    if (strcmp(operation, "ble") == 0) {
        ib_wifi_request_bluetooth();
        status("ble", NULL);
        cJSON_Delete(root);
        vTaskDelay(pdMS_TO_TICKS(150));
        esp_restart();
        return true;
    }

    if (strcmp(operation, "select") == 0 || strcmp(operation, "remove") == 0) {
        const cJSON *ssid = cJSON_GetObjectItemCaseSensitive(root, "ssid");
        ib_wifi_store_t store = store_snapshot();
        int index = cJSON_IsString(ssid) ? ib_wifi_store_find(&store, ssid->valuestring) : -1;
        bool ok = index >= 0;
        if (ok && strcmp(operation, "select") == 0) ok = ib_wifi_store_set_active(&store, (uint8_t)index);
        if (ok && strcmp(operation, "remove") == 0) ok = ib_wifi_store_remove(&store, ssid->valuestring);
        ok = ok && save_store(&store);
        if (ok) {
            replace_store(&store);
            ib_wifi_network_t active = { 0 };
            if (active_network(&store, &active)) {
                portENTER_CRITICAL(&s_lock);
                s_config = active;
                portEXIT_CRITICAL(&s_lock);
            } else {
                portENTER_CRITICAL(&s_lock);
                memset(&s_config, 0, sizeof(s_config));
                portEXIT_CRITICAL(&s_lock);
            }
            memset(&active, 0, sizeof(active));
            ib_wifi_clear_ble_fallback();
            status(store.count ? "connecting" : "unconfigured", NULL);
            cJSON_Delete(root);
            vTaskDelay(pdMS_TO_TICKS(150));
            esp_restart();
            return true;
        }
        status("config_error", NULL);
        cJSON_Delete(root);
        return true;
    }

    if (!allow_provisioning) { cJSON_Delete(root); return false; }
    if (strcmp(operation, "add") != 0) {
        status("config_error", NULL);
        cJSON_Delete(root);
        return true;
    }

    const cJSON *ssid = cJSON_GetObjectItemCaseSensitive(root, "ssid");
    const cJSON *password = cJSON_GetObjectItemCaseSensitive(root, "password");
    const cJSON *host = cJSON_GetObjectItemCaseSensitive(root, "host");
    const cJSON *key = cJSON_GetObjectItemCaseSensitive(root, "psk");
    ib_wifi_network_t config = { 0 };
    bool valid = cJSON_IsString(ssid) && strlen(ssid->valuestring) > 0 && strlen(ssid->valuestring) <= 32
        && cJSON_IsString(password) && strlen(password->valuestring) <= 63
        && (strlen(password->valuestring) == 0 || strlen(password->valuestring) >= 8)
        && cJSON_IsString(host) && strlen(host->valuestring) >= 4 && strlen(host->valuestring) < sizeof(config.host)
        && cJSON_IsString(key) && strlen(key->valuestring) == 64;
    if (valid) {
        for (size_t i = 0; i < strlen(host->valuestring); i++) {
            char c = host->valuestring[i]; if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) valid = false;
        }
        for (int i = 0; i < 32; i++) {
            int a = hex_digit(key->valuestring[i * 2]), b = hex_digit(key->valuestring[i * 2 + 1]);
            if (a < 0 || b < 0) { valid = false; break; }
            config.key[i] = (uint8_t)((a << 4) | b);
        }
    }
    if (valid) {
        strcpy(config.ssid, ssid->valuestring); strcpy(config.password, password->valuestring); strcpy(config.host, host->valuestring);
        ib_wifi_store_t store = store_snapshot();
        int index = ib_wifi_store_add(&store, &config);
        valid = index >= 0 && ib_wifi_store_set_active(&store, (uint8_t)index) && save_store(&store);
        if (valid) {
            replace_store(&store);
            portENTER_CRITICAL(&s_lock);
            s_config = config;
            portEXIT_CRITICAL(&s_lock);
        }
    }
    if (!valid) status(s_available ? "config_error" : "network_error", NULL);
    memset(&config, 0, sizeof(config));
    cJSON_Delete(root);
    // 新增或切换网络都重启到新的 host / PSK；C3 上同时保留两套无线协议栈会挤掉音频 DMA。
    if (valid) {
        ib_wifi_clear_ble_fallback();
        status("connecting", NULL);
        vTaskDelay(pdMS_TO_TICKS(150));
        esp_restart();
    }
    return true;
}

bool ib_wifi_handle_usb_line(const char *line, size_t len)
{
    return ib_wifi_handle_control_line(line, len, true);
}

esp_err_t ib_wifi_start(ib_wifi_line_cb_t line, ib_wifi_link_cb_t link)
{
    ib_wifi_clear_ble_fallback();
    s_line = line; s_link = link;
    ib_wifi_store_t store = store_snapshot();
    if (!store.count) return ESP_OK;
    s_events = xEventGroupCreate();
    s_config_queue = xQueueCreate(1, sizeof(ib_wifi_network_t));
    s_control_tx = xQueueCreate(4, sizeof(packet_t));
    s_audio_tx = xQueueCreate(4, sizeof(packet_t));
    if (!s_events || !s_config_queue || !s_control_tx || !s_audio_tx) return ESP_ERR_NO_MEM;
    esp_err_t error = esp_netif_init(); if (error != ESP_OK) return error;
    error = esp_event_loop_create_default(); if (error != ESP_OK && error != ESP_ERR_INVALID_STATE) return error;
    s_netif = esp_netif_create_default_wifi_sta(); if (!s_netif) return ESP_ERR_NO_MEM;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if ((error = esp_wifi_init(&init)) != ESP_OK) return error;
    if ((error = esp_wifi_set_storage(WIFI_STORAGE_RAM)) != ESP_OK) return error;
    if ((error = esp_wifi_set_mode(WIFI_MODE_STA)) != ESP_OK) return error;
    if ((error = esp_wifi_set_ps(WIFI_PS_NONE)) != ESP_OK) return error;
    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_event, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_event, NULL);
    if ((error = mdns_init()) != ESP_OK) return error;
    mdns_hostname_set("folobutton");
    mdns_instance_name_set("FoloButton");
    mdns_service_add(NULL, "_folobutton", "_tcp", WIFI_PORT, NULL, 0);
    if (xTaskCreate(config_task, "ib_wifi_cfg", 4096, NULL, 4, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    if (xTaskCreate(server_task, "ib_wifi_tls", 8192, NULL, 4, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    const esp_timer_create_args_t timer_args = {
        .callback = handshake_timeout,
        .name = "ib_wifi_hs",
    };
    if (esp_timer_create(&timer_args, &s_handshake_timer) != ESP_OK) return ESP_ERR_NO_MEM;
    const esp_timer_create_args_t reconnect_args = {
        .callback = reconnect_timer_cb,
        .name = "ib_wifi_retry",
    };
    if (esp_timer_create(&reconnect_args, &s_reconnect_timer) != ESP_OK) return ESP_ERR_NO_MEM;
    s_reconnect_delay_ms = 1000;
    s_available = true;
    ib_wifi_network_t config;
    if (active_network(&store, &config)) xQueueOverwrite(s_config_queue, &config);
    memset(&config, 0, sizeof(config));
    return ESP_OK;
}

size_t ib_wifi_network_count(void)
{
    return store_snapshot().count;
}

size_t ib_wifi_active_network(void)
{
    ib_wifi_store_t store = store_snapshot();
    return store.count ? store.active : 0;
}

bool ib_wifi_network_name(size_t index, char *out, size_t cap)
{
    ib_wifi_store_t store = store_snapshot();
    if (!out || cap == 0 || index >= store.count) return false;
    snprintf(out, cap, "%s", store.networks[index].ssid);
    return true;
}

bool ib_wifi_select_network(size_t index)
{
    ib_wifi_store_t store = store_snapshot();
    if (index >= store.count || !ib_wifi_store_set_active(&store, (uint8_t)index) || !save_store(&store)) return false;
    replace_store(&store);
    ib_wifi_network_t active = { 0 };
    active_network(&store, &active);
    portENTER_CRITICAL(&s_lock);
    s_config = active;
    portEXIT_CRITICAL(&s_lock);
    status("connecting", NULL);
    return true;
}
