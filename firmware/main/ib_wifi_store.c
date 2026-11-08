#include "ib_wifi_store.h"

#include <string.h>

static bool text_valid(const char *text, size_t size, bool required)
{
    return memchr(text, 0, size) && (!required || text[0]);
}

bool ib_wifi_network_valid(const ib_wifi_network_t *network)
{
    return network
        && text_valid(network->ssid, sizeof(network->ssid), true)
        && text_valid(network->password, sizeof(network->password), false)
        && text_valid(network->host, sizeof(network->host), true);
}

bool ib_wifi_store_valid(const ib_wifi_store_t *store)
{
    if (!store || store->version != IB_WIFI_STORE_VERSION || store->count > IB_WIFI_MAX_NETWORKS) return false;
    if (store->count && store->active >= store->count) return false;
    for (uint8_t i = 0; i < store->count; i++) {
        if (!ib_wifi_network_valid(&store->networks[i])) return false;
        for (uint8_t j = 0; j < i; j++) {
            if (strcmp(store->networks[i].ssid, store->networks[j].ssid) == 0) return false;
        }
    }
    return true;
}

void ib_wifi_store_init(ib_wifi_store_t *store)
{
    memset(store, 0, sizeof(*store));
    store->version = IB_WIFI_STORE_VERSION;
}

int ib_wifi_store_find(const ib_wifi_store_t *store, const char *ssid)
{
    if (!store || !ssid) return -1;
    for (uint8_t i = 0; i < store->count; i++) {
        if (strcmp(store->networks[i].ssid, ssid) == 0) return i;
    }
    return -1;
}

int ib_wifi_store_add(ib_wifi_store_t *store, const ib_wifi_network_t *network)
{
    if (!store || !ib_wifi_network_valid(network)) return -1;
    int index = ib_wifi_store_find(store, network->ssid);
    if (index < 0) {
        if (store->count >= IB_WIFI_MAX_NETWORKS) return -1;
        index = store->count++;
    }
    store->networks[index] = *network;
    if (store->count == 1) store->active = 0;
    return index;
}

bool ib_wifi_store_remove(ib_wifi_store_t *store, const char *ssid)
{
    int index = ib_wifi_store_find(store, ssid);
    if (index < 0) return false;
    for (uint8_t i = (uint8_t)index; i + 1 < store->count; i++) {
        store->networks[i] = store->networks[i + 1];
    }
    store->count--;
    memset(&store->networks[store->count], 0, sizeof(store->networks[0]));
    if (store->count == 0) {
        store->active = 0;
    } else {
        if (store->active > index) store->active--;
        if (store->active >= store->count) store->active = 0;
    }
    return true;
}

bool ib_wifi_store_set_active(ib_wifi_store_t *store, uint8_t active)
{
    if (!store || active >= store->count) return false;
    store->active = active;
    return true;
}

bool ib_wifi_store_from_legacy(ib_wifi_store_t *store, const void *data, size_t len)
{
    if (!store || !data || len != sizeof(ib_wifi_legacy_t)) return false;
    ib_wifi_legacy_t legacy;
    memcpy(&legacy, data, sizeof(legacy));
    if (legacy.version != 1) return false;
    ib_wifi_network_t network = { 0 };
    memcpy(network.ssid, legacy.ssid, sizeof(network.ssid));
    memcpy(network.password, legacy.password, sizeof(network.password));
    memcpy(network.host, legacy.host, sizeof(network.host));
    memcpy(network.key, legacy.key, sizeof(network.key));
    if (!ib_wifi_network_valid(&network)) return false;
    ib_wifi_store_init(store);
    store->count = 1;
    store->active = 0;
    store->networks[0] = network;
    return true;
}
