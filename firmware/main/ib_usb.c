// main/ib_usb.c: USB Serial/JTAG 链路。
//
// 安装驱动并让 VFS stdout 走驱动:
//   - 接收任务阻塞在 usb_serial_jtag_read_bytes() 上读取 Mac 命令;
//   - 协议文本行与音频二进制帧都直接写驱动发送环:一次调用整段原子入队,放不下就整段丢弃,
//     不会发出半行 JSON;
//   - 日志经 VFS 逐字节写入同一个发送环,所以协议行/帧可能夹在一条日志中间。
//     Mac 只从 {"t": 处开始解析一行,并在二进制帧结束后继续拼接文本,协议允许这种穿插。
#include "ib_usb.h"

#include "ib_protocol.h"

#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"


static const char *TAG = "ib_usb";

#define RX_TASK_STACK       3072
#define RX_TASK_PRIO        5
// 发送环要放得下两个音频帧(2 x 334 字节)加上文本行与日志。
#define TX_RING_BYTES       4096
#define RX_RING_BYTES       1024
#define BIN_SEND_TIMEOUT_MS  20
#define TEXT_SEND_TIMEOUT_MS 50

static ib_usb_line_cb_t s_on_line;
static ib_line_t s_line;        // 只在接收任务中访问

static void dispatch(const char *line, size_t len, void *user)
{
    (void)user;
    s_on_line(line, len);
}

static void rx_task(void *arg)
{
    (void)arg;
    static uint8_t buf[256];
    for (;;) {
        int n = usb_serial_jtag_read_bytes(buf, sizeof(buf), portMAX_DELAY);
        if (n > 0) ib_line_feed(&s_line, buf, (size_t)n, dispatch, NULL);
    }
}

esp_err_t ib_usb_start(ib_usb_line_cb_t on_line)
{
    s_on_line = on_line;
    ib_line_init(&s_line);

    usb_serial_jtag_driver_config_t cfg = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    cfg.tx_buffer_size = TX_RING_BYTES;
    cfg.rx_buffer_size = RX_RING_BYTES;
    ESP_RETURN_ON_ERROR(usb_serial_jtag_driver_install(&cfg), TAG, "driver install failed");
    usb_serial_jtag_vfs_use_driver();

    BaseType_t ok = xTaskCreate(rx_task, "ib_usb_rx", RX_TASK_STACK, NULL, RX_TASK_PRIO, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "rx task create failed");
    return ESP_OK;
}

void ib_usb_send(const char *data, size_t len)
{
    if (len == 0 || !usb_serial_jtag_is_connected()) return;
    if (len > TX_RING_BYTES / 2) return;
    usb_serial_jtag_write_bytes(data, len, pdMS_TO_TICKS(TEXT_SEND_TIMEOUT_MS));
}

void ib_usb_send_bin(const uint8_t *frame, size_t len)
{
    if (len == 0 || len > TX_RING_BYTES / 2 || !usb_serial_jtag_is_connected()) return;
    usb_serial_jtag_write_bytes(frame, len, pdMS_TO_TICKS(BIN_SEND_TIMEOUT_MS));
}

bool ib_usb_host_present(void)
{
    return usb_serial_jtag_is_connected();
}
