#!/usr/bin/env bash
# 生成 Matrix 终端使用的 Roboto Mono ASCII 字体;依赖 Node.js、curl、shasum。
# Google Fonts 固定提交,Roboto Mono: SIL Open Font License 1.1。
# 两个下载文件都校验 SHA-256,转换器固定 lv_font_conv 1.5.3。
set -euo pipefail

commit="eb20e9cf19d97cf579fa3867d729d4222d6c59e1"
base="https://raw.githubusercontent.com/google/fonts/${commit}/ofl/robotomono"
fw="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ib-terminal-font.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
cd "${work}"
curl -fsSL "${base}/RobotoMono%5Bwght%5D.ttf" -o RobotoMono.ttf
curl -fsSL "${base}/OFL.txt" -o OFL.txt
printf '%s  %s\n' \
    66a80e79d17e4c7cabd162e2916578a4cc08fd19eef6e2a643305eae9c567b2b RobotoMono.ttf \
    50ab8dd54680d3473f649c9db86fece88434d097c7834475c1c72d2f8c429215 OFL.txt | shasum -a 256 -c -
for size in 12 14 20; do
    npx --yes lv_font_conv@1.5.3 --font RobotoMono.ttf --range 0x20-0x7e --size "${size}" --bpp 4 \
        --format lvgl --no-compress --no-kerning --lv-include lvgl.h --lv-font-name "ib_terminal_font_${size}" \
        --output "ib_terminal_font_${size}.c"
    cp "ib_terminal_font_${size}.c" "${fw}/main/fonts/"
done
cp OFL.txt "${fw}/main/fonts/LICENSE-roboto-mono"
