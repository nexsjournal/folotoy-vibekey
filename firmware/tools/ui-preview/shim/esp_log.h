// tools/ui-preview/shim/esp_log.h: 主机替身,日志打印到 stderr。
#pragma once

#include <stdio.h>

#define IB_PREVIEW_LOG(level, tag, fmt, ...) fprintf(stderr, level " (%s) " fmt "\n", tag, ##__VA_ARGS__)
#define ESP_LOGE(tag, fmt, ...) IB_PREVIEW_LOG("E", tag, fmt, ##__VA_ARGS__)
#define ESP_LOGW(tag, fmt, ...) IB_PREVIEW_LOG("W", tag, fmt, ##__VA_ARGS__)
#define ESP_LOGI(tag, fmt, ...) IB_PREVIEW_LOG("I", tag, fmt, ##__VA_ARGS__)
#define ESP_LOGD(tag, fmt, ...) do { } while (0)
