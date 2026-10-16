// tools/ui-preview/preview_scenarios.h: 预览场景:按 ib_app 的调用方式驱动 ib_ui_* 接口并逐帧截图。
#pragma once

// 依次运行所有场景,截图写到 out_dir/<序号>_<名称>.png(放大 scale 倍)。
// filter 非 NULL 时只保存文件名包含该子串的截图(场景仍完整运行,保证状态连续)。
// 返回保存失败的截图数。
int preview_run_scenarios(const char *out_dir, int scale, const char *filter);
