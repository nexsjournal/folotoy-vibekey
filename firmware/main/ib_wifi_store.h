// main/ib_wifi_store.h: Wi-Fi 多网络记录的纯数据模型(不依赖 ESP-IDF)。
//
// 每条网络独立保存 host 与 TLS-PSK。切换网络后会同时切换 mDNS 主机名和密钥，
// 不能把一台设备的 host / PSK 复用到多组 SSID 上。
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define IB_WIFI_MAX_NETWORKS 4
#define IB_WIFI_SSID_MAX 33
#define IB_WIFI_PASSWORD_MAX 65
#define IB_WIFI_HOST_MAX 32
#define IB_WIFI_KEY_SIZE 32
#define IB_WIFI_STORE_VERSION 2

typedef struct {
    char ssid[IB_WIFI_SSID_MAX];
    char password[IB_WIFI_PASSWORD_MAX];
    char host[IB_WIFI_HOST_MAX];
    uint8_t key[IB_WIFI_KEY_SIZE];
} ib_wifi_network_t;

typedef struct {
    uint32_t version;
    uint8_t count;
    uint8_t active;
    uint8_t reserved[2];
    ib_wifi_network_t networks[IB_WIFI_MAX_NETWORKS];
} ib_wifi_store_t;

// 固件 0.1.5 及更早的单网络 NVS 结构，仅用于启动时迁移。
typedef struct {
    uint32_t version;
    char ssid[IB_WIFI_SSID_MAX];
    char password[IB_WIFI_PASSWORD_MAX];
    char host[IB_WIFI_HOST_MAX];
    uint8_t key[IB_WIFI_KEY_SIZE];
} ib_wifi_legacy_t;

bool ib_wifi_network_valid(const ib_wifi_network_t *network);
bool ib_wifi_store_valid(const ib_wifi_store_t *store);
void ib_wifi_store_init(ib_wifi_store_t *store);
int ib_wifi_store_find(const ib_wifi_store_t *store, const char *ssid);
// 同 SSID 覆盖原记录；成功返回下标，记录已满返回 -1。active 由调用方设置。
int ib_wifi_store_add(ib_wifi_store_t *store, const ib_wifi_network_t *network);
bool ib_wifi_store_remove(ib_wifi_store_t *store, const char *ssid);
bool ib_wifi_store_set_active(ib_wifi_store_t *store, uint8_t active);
// version 1 的单网络结构迁移为 version 2；只接受大小与内容都合法的旧记录。
bool ib_wifi_store_from_legacy(ib_wifi_store_t *store, const void *data, size_t len);
