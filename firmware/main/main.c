// main/main.c: InputBetter Passport 固件入口。
//
// Passport 作为 InputBetter macOS app 的"瘦终端":上报按键、显示 Mac 下发的状态、推送麦克风音频。
// 协议见仓库 docs/protocol.md,界面见 docs/device-ui.md。
//
// 初始化顺序:共享 I2C → 显示 / LVGL → 电量计 → 应用(UI、USB、BLE、音频、应用任务)→ 按键。
// 按键最后初始化,保证第一次按键回调时事件队列已经建立。
#include "bsp_battery.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "bsp_i2c.h"
#include "ib_app.h"

#include "esp_log.h"

static const char *TAG = "main";

void app_main(void)
{
    bsp_i2c_init();

    // 屏幕失败时按键与音频照常工作,不中止启动。
    bool ui_ok = bsp_display_init() == ESP_OK && bsp_lvgl_init() != NULL;
    if (!ui_ok) ESP_LOGE(TAG, "display/LVGL init failed, running headless");

    bool battery_ok = bsp_battery_init() == ESP_OK;

    if (ib_app_start(ui_ok, battery_ok) != ESP_OK) {
        ESP_LOGE(TAG, "app start failed");
        return;
    }
    if (bsp_button_init(ib_app_on_button, NULL) != ESP_OK) ESP_LOGE(TAG, "button init failed");
}
