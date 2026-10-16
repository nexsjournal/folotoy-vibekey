#!/usr/bin/env bash
# 一条命令生成 Passport 界面预览图:编译主机预览程序并把所有场景截图写到 tools/ui-preview/out/。
#
# 用法:tools/ui-preview/run.sh [过滤子串]
#   例:tools/ui-preview/run.sh list      只保存文件名含 "list" 的截图
# 环境变量:SCALE(放大倍数,默认 2,即 480x640)
#
# 依赖:cmake、clang(Xcode Command Line Tools)。LVGL 源码与 sdkconfig.h 来自固件编译产物,
# 第一次使用前先在 firmware/ 下执行一次 idf.py build。
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build="${here}/build"
out="${here}/out"
scale="${SCALE:-2}"

cmake -S "${here}" -B "${build}" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang >/dev/null
cmake --build "${build}" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >/dev/null
rm -rf "${out}"
mkdir -p "${out}"
"${build}/ib_ui_preview" "${out}" "${scale}" "${1:-}"
