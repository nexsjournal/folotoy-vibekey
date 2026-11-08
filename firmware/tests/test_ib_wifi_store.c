// tests/test_ib_wifi_store.c: Wi-Fi 多网络记录、迁移与增删切换的主机测试。
#include "ib_wifi_store.h"
#include "test_common.h"

#include <string.h>

static ib_wifi_network_t make_network(const char *ssid, const char *host)
{
    ib_wifi_network_t network = { 0 };
    snprintf(network.ssid, sizeof(network.ssid), "%s", ssid);
    snprintf(network.password, sizeof(network.password), "password-%s", ssid);
    snprintf(network.host, sizeof(network.host), "%s", host);
    memset(network.key, 0x5a, sizeof(network.key));
    return network;
}

static void test_add_select_remove(void)
{
    ib_wifi_store_t store;
    ib_wifi_store_init(&store);
    CHECK(ib_wifi_store_valid(&store));

    ib_wifi_network_t home = make_network("Home", "fb-home");
    ib_wifi_network_t office = make_network("Office", "fb-office");
    CHECK(ib_wifi_store_add(&store, &home) == 0);
    CHECK(ib_wifi_store_add(&store, &office) == 1);
    CHECK(store.count == 2);
    CHECK(ib_wifi_store_set_active(&store, 1));
    CHECK(store.active == 1);

    // 同 SSID 覆盖，不新增记录，也不打乱当前 active。
    ib_wifi_network_t updated = make_network("Home", "fb-home-2");
    CHECK(ib_wifi_store_add(&store, &updated) == 0);
    CHECK(store.count == 2 && store.active == 1);
    CHECK_STR(store.networks[0].host, "fb-home-2");

    // 删除 active 前的记录时 active 前移，仍指向 Office。
    CHECK(ib_wifi_store_remove(&store, "Home"));
    CHECK(store.count == 1 && store.active == 0);
    CHECK_STR(store.networks[0].ssid, "Office");

    CHECK(ib_wifi_store_remove(&store, "Office"));
    CHECK(store.count == 0 && store.active == 0);
    CHECK(!ib_wifi_store_remove(&store, "missing"));
}

static void test_capacity_and_validation(void)
{
    ib_wifi_store_t store;
    ib_wifi_store_init(&store);
    for (int i = 0; i < IB_WIFI_MAX_NETWORKS; i++) {
        char ssid[8];
        snprintf(ssid, sizeof(ssid), "net%d", i);
        ib_wifi_network_t network = make_network(ssid, "fb-host");
        CHECK(ib_wifi_store_add(&store, &network) == i);
    }
    ib_wifi_network_t extra = make_network("extra", "fb-extra");
    CHECK(ib_wifi_store_add(&store, &extra) == -1);

    ib_wifi_network_t invalid = make_network("", "fb-empty");
    CHECK(!ib_wifi_network_valid(&invalid));
    store.count = IB_WIFI_MAX_NETWORKS + 1;
    CHECK(!ib_wifi_store_valid(&store));
}

static void test_legacy_migration(void)
{
    ib_wifi_legacy_t legacy = { .version = 1 };
    snprintf(legacy.ssid, sizeof(legacy.ssid), "旧网络");
    snprintf(legacy.password, sizeof(legacy.password), "12345678");
    snprintf(legacy.host, sizeof(legacy.host), "fb-legacy");
    memset(legacy.key, 0x33, sizeof(legacy.key));

    ib_wifi_store_t store;
    CHECK(ib_wifi_store_from_legacy(&store, &legacy, sizeof(legacy)));
    CHECK(ib_wifi_store_valid(&store));
    CHECK(store.count == 1 && store.active == 0);
    CHECK_STR(store.networks[0].ssid, "旧网络");
    CHECK(store.networks[0].key[0] == 0x33);

    legacy.version = 2;
    CHECK(!ib_wifi_store_from_legacy(&store, &legacy, sizeof(legacy)));
    CHECK(!ib_wifi_store_from_legacy(&store, &legacy, sizeof(legacy) - 1));
}

int main(void)
{
    test_add_select_remove();
    test_capacity_and_validation();
    test_legacy_migration();
    TEST_DONE("test_ib_wifi_store");
}
