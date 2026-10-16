// tools/ui-preview/preview_main.c: 预览程序入口。
//
// 用法:ib_ui_preview <输出目录> [放大倍数,默认 2] [只保存文件名含此子串的截图]
#include "ib_ui.h"
#include "preview_host.h"
#include "preview_scenarios.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <out_dir> [scale] [filter]\n", argv[0]);
        return 2;
    }
    const char *out_dir = argv[1];
    int scale = argc > 2 ? atoi(argv[2]) : 2;
    const char *filter = argc > 3 ? argv[3] : NULL;
    if (scale < 1 || scale > 8) scale = 2;

    preview_init();
    if (ib_ui_init() != ESP_OK) {
        fprintf(stderr, "ib_ui_init failed\n");
        return 1;
    }
    preview_advance(100);

    int failures = preview_run_scenarios(out_dir, scale, filter);
    printf("LVGL 内存池峰值 %u 字节(主机 64 位,仅供参考)\n", (unsigned)preview_mem_max_used());
    return failures == 0 ? 0 : 1;
}
