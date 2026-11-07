// Wi-Fi 与 TLS 分开运行：配置任务管理网络；服务器任务独占 TLS 会话，音频任务只投递发送队列。
#include "ib_wifi.h"
#include "ib_protocol.h"
#include "ib_usb.h"
#include "cJSON.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_system.h"
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
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#define WIFI_PORT 8765
#define IP_READY BIT0
#define CONFIG_VERSION 1
// 最大上行音频帧 334 字节，JSON 回复也小于 512；无需为每个队列项预留 1 KB。
#define PACKET_MAX 512
typedef struct { uint32_t version; char ssid[33]; char password[65]; char host[32]; uint8_t key[32]; } wifi_config_store_t;
typedef struct { size_t len; uint8_t bytes[PACKET_MAX]; } packet_t;
static QueueHandle_t s_config_queue, s_tx;
static EventGroupHandle_t s_events;
static ib_wifi_line_cb_t s_line;
static ib_wifi_link_cb_t s_link;
static wifi_config_store_t s_config;
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static volatile uint32_t s_generation;
static volatile bool s_configured, s_session;
static volatile bool s_available;
static char s_stage[24] = "unconfigured";
static esp_netif_t *s_netif;

static bool load_config(wifi_config_store_t *config)
{
    nvs_handle_t nvs;
    size_t size = sizeof(*config);
    if (nvs_open("ib_wifi", NVS_READONLY, &nvs) != ESP_OK) return false;
    bool valid = nvs_get_blob(nvs, "config", config, &size) == ESP_OK && size == sizeof(*config)
        && config->version == CONFIG_VERSION
        && memchr(config->ssid, 0, sizeof(config->ssid)) && config->ssid[0]
        && memchr(config->password, 0, sizeof(config->password))
        && memchr(config->host, 0, sizeof(config->host)) && config->host[0];
    nvs_close(nvs);
    return valid;
}

bool ib_wifi_is_configured(void)
{
    wifi_config_store_t config;
    bool configured = load_config(&config);
    memset(&config, 0, sizeof(config));
    return configured;
}

static void status(const char *stage, const char *ip)
{
    char out[512], host[32], ssid[33];
    portENTER_CRITICAL(&s_lock);
    snprintf(s_stage, sizeof(s_stage), "%s", stage);
    memcpy(host, s_config.host, sizeof(host));
    memcpy(ssid, s_config.ssid, sizeof(ssid));
    portEXIT_CRITICAL(&s_lock);
    cJSON *root = cJSON_CreateObject();
    if (!root) return;
    cJSON_AddStringToObject(root, "t", "wifi");
    cJSON_AddStringToObject(root, "stage", stage);
    cJSON_AddStringToObject(root, "host", host);
    cJSON_AddStringToObject(root, "ssid", ssid);
    cJSON_AddStringToObject(root, "ip", ip ? ip : "");
    cJSON_AddNumberToObject(root, "heap", esp_get_free_heap_size());
    if (cJSON_PrintPreallocated(root, out, sizeof(out) - 1, false)) {
        size_t n = strlen(out); out[n++] = '\n'; ib_usb_send(out, n);
    }
    cJSON_Delete(root);
}

void ib_wifi_report_status(void)
{
    char stage[24], ip[16] = "";
    portENTER_CRITICAL(&s_lock); memcpy(stage, s_stage, sizeof(stage)); portEXIT_CRITICAL(&s_lock);
    if (!s_available && ib_wifi_is_configured()) strcpy(stage, "network_error");
    if (s_netif && s_available) {
        esp_netif_ip_info_t info;
        if (esp_netif_get_ip_info(s_netif, &info) == ESP_OK && info.ip.addr) {
            snprintf(ip, sizeof(ip), IPSTR, IP2STR(&info.ip));
        }
    }
    status(stage, ip);
}

static void network_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) esp_wifi_connect();
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        xEventGroupClearBits(s_events, IP_READY);
        const wifi_event_sta_disconnected_t *event = data;
        const char *stage = (event->reason == WIFI_REASON_AUTH_FAIL || event->reason == WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT)
            ? "auth_error" : event->reason == WIFI_REASON_NO_AP_FOUND ? "not_found" : "connecting";
        status(stage, NULL);
        if (s_configured) esp_wifi_connect();
    }
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = data;
        char ip[16]; snprintf(ip, sizeof(ip), IPSTR, IP2STR(&event->ip_info.ip));
        xEventGroupSetBits(s_events, IP_READY);
        status("ready", ip);
    }
}

static void line_received(const char *line, size_t len, void *user)
{
    (void)user;
    if (s_line) s_line(line, len);
}

// 任意任务可调用，队列满时丢弃当前音频帧；独立 ADPCM 块与序号允许接收端检测并恢复。
void ib_wifi_send(const uint8_t *data, size_t len)
{
    if (!s_session || !s_tx || len == 0 || len > PACKET_MAX) return;
    packet_t packet = { .len = len };
    memcpy(packet.bytes, data, len);
    xQueueSend(s_tx, &packet, 0);
}

static bool tls_write_all(esp_tls_t *tls, const uint8_t *data, size_t len)
{
    size_t offset = 0;
    while (offset < len) {
        int n = esp_tls_conn_write(tls, data + offset, len - offset);
        if (n <= 0) return false;
        offset += (size_t)n;
    }
    return true;
}

static void server_task(void *arg)
{
    (void)arg;
    int listener = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    if (listener < 0) { status("server_error", NULL); vTaskDelete(NULL); return; }
    int reuse = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(WIFI_PORT), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 1) != 0) {
        close(listener); status("server_error", NULL); vTaskDelete(NULL); return;
    }
    for (;;) {
        xEventGroupWaitBits(s_events, IP_READY, pdFALSE, pdTRUE, portMAX_DELAY);
        int socket_fd = accept(listener, NULL, NULL);
        if (socket_fd < 0) { vTaskDelay(pdMS_TO_TICKS(100)); continue; }
        struct timeval timeout = { .tv_sec = 4, .tv_usec = 0 };
        setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        wifi_config_store_t config;
        portENTER_CRITICAL(&s_lock); config = s_config; uint32_t generation = s_generation; portEXIT_CRITICAL(&s_lock);
        psk_hint_key_t psk = { .key = config.key, .key_size = sizeof(config.key), .hint = "folobutton" };
        esp_tls_cfg_server_t tls_config = { .psk_hint_key = &psk };
        esp_tls_t *tls = esp_tls_init();
        if (!tls || esp_tls_server_session_create(&tls_config, socket_fd, tls) != 0) {
            if (tls) esp_tls_server_session_delete(tls); else close(socket_fd);
            memset(&config, 0, sizeof(config)); continue;
        }
        xQueueReset(s_tx);
        s_session = true;
        if (s_link) s_link(true);
        ib_line_t lines; ib_line_init(&lines);
        uint8_t input[512]; packet_t outgoing;
        bool alive = true;
        while (alive && generation == s_generation && (xEventGroupGetBits(s_events) & IP_READY)) {
            while (xQueueReceive(s_tx, &outgoing, 0) == pdTRUE) {
                if (!tls_write_all(tls, outgoing.bytes, outgoing.len)) { alive = false; break; }
            }
            fd_set reads; FD_ZERO(&reads); FD_SET(socket_fd, &reads);
            struct timeval wait = { .tv_usec = 5000 };
            int ready = select(socket_fd + 1, &reads, NULL, NULL, &wait);
            if (ready < 0) break;
            if (ready > 0 || esp_tls_get_bytes_avail(tls) > 0) {
                int n = esp_tls_conn_read(tls, input, sizeof(input));
                if (n <= 0) break;
                ib_line_feed(&lines, input, n, line_received, NULL);
            }
        }
        s_session = false;
        if (s_link) s_link(false);
        esp_tls_server_session_delete(tls);
        memset(&config, 0, sizeof(config));
    }
}

static void config_task(void *arg)
{
    (void)arg;
    wifi_config_store_t next;
    for (;;) {
        if (xQueueReceive(s_config_queue, &next, portMAX_DELAY) != pdTRUE) continue;
        s_configured = false;
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

bool ib_wifi_handle_usb_line(const char *line, size_t len)
{
    // Wi-Fi 凭据保留 UTF-8，不经过屏幕协议的 ASCII 文本归一化。
    cJSON *root = cJSON_ParseWithLength(line, len);
    if (!root) return false;
    const cJSON *command = cJSON_GetObjectItemCaseSensitive(root, "cmd");
    if (!cJSON_IsString(command) || strcmp(command->valuestring, "wifi") != 0) { cJSON_Delete(root); return false; }
    const cJSON *clear = cJSON_GetObjectItemCaseSensitive(root, "clear");
    if (cJSON_IsNumber(clear) && clear->valueint == 1) {
        nvs_handle_t nvs;
        bool cleared = nvs_open("ib_wifi", NVS_READWRITE, &nvs) == ESP_OK;
        if (cleared) {
            esp_err_t error = nvs_erase_key(nvs, "config");
            cleared = (error == ESP_OK || error == ESP_ERR_NVS_NOT_FOUND) && nvs_commit(nvs) == ESP_OK;
            nvs_close(nvs);
        }
        cJSON_Delete(root);
        status(cleared ? "unconfigured" : "config_error", NULL);
        if (cleared) { vTaskDelay(pdMS_TO_TICKS(150)); esp_restart(); }
        return true;
    }
    const cJSON *ssid = cJSON_GetObjectItemCaseSensitive(root, "ssid");
    const cJSON *password = cJSON_GetObjectItemCaseSensitive(root, "password");
    const cJSON *host = cJSON_GetObjectItemCaseSensitive(root, "host");
    const cJSON *key = cJSON_GetObjectItemCaseSensitive(root, "psk");
    wifi_config_store_t config = { .version = CONFIG_VERSION };
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
        nvs_handle_t nvs;
        valid = nvs_open("ib_wifi", NVS_READWRITE, &nvs) == ESP_OK;
        if (valid) { valid = nvs_set_blob(nvs, "config", &config, sizeof(config)) == ESP_OK && nvs_commit(nvs) == ESP_OK; nvs_close(nvs); }
        if (valid && s_available) { xQueueOverwrite(s_config_queue, &config); }
    }
    if (!valid) status(s_available ? "config_error" : "network_error", NULL);
    memset(&config, 0, sizeof(config));
    cJSON_Delete(root);
    // 未配网时只运行 BLE；第一次 USB 配网后重启切 Wi-Fi，避免两套协议栈挤掉音频 DMA。
    if (valid && !s_available) { status("connecting", NULL); vTaskDelay(pdMS_TO_TICKS(150)); esp_restart(); }
    return true;
}

esp_err_t ib_wifi_start(ib_wifi_line_cb_t line, ib_wifi_link_cb_t link)
{
    s_line = line; s_link = link;
    if (!ib_wifi_is_configured()) return ESP_OK;
    s_events = xEventGroupCreate();
    s_config_queue = xQueueCreate(1, sizeof(wifi_config_store_t));
    s_tx = xQueueCreate(8, sizeof(packet_t));
    if (!s_events || !s_config_queue || !s_tx) return ESP_ERR_NO_MEM;
    esp_err_t error = esp_netif_init(); if (error != ESP_OK) return error;
    error = esp_event_loop_create_default(); if (error != ESP_OK && error != ESP_ERR_INVALID_STATE) return error;
    s_netif = esp_netif_create_default_wifi_sta(); if (!s_netif) return ESP_ERR_NO_MEM;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if ((error = esp_wifi_init(&init)) != ESP_OK) return error;
    if ((error = esp_wifi_set_storage(WIFI_STORAGE_RAM)) != ESP_OK) return error;
    if ((error = esp_wifi_set_mode(WIFI_MODE_STA)) != ESP_OK) return error;
    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_event, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_event, NULL);
    if ((error = mdns_init()) != ESP_OK) return error;
    mdns_hostname_set("folobutton");
    mdns_instance_name_set("FoloButton");
    mdns_service_add(NULL, "_folobutton", "_tcp", WIFI_PORT, NULL, 0);
    if (xTaskCreate(config_task, "ib_wifi_cfg", 4096, NULL, 4, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    if (xTaskCreate(server_task, "ib_wifi_tls", 8192, NULL, 4, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    s_available = true;
    wifi_config_store_t config;
    if (load_config(&config)) xQueueOverwrite(s_config_queue, &config);
    memset(&config, 0, sizeof(config));
    return ESP_OK;
}
