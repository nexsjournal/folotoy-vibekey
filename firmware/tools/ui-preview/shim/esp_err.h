// tools/ui-preview/shim/esp_err.h: 主机替身,只提供 UI 代码用到的错误码。
#pragma once

typedef int esp_err_t;

#define ESP_OK          0
#define ESP_FAIL        (-1)
#define ESP_ERR_NO_MEM  0x101
#define ESP_ERR_TIMEOUT 0x107
