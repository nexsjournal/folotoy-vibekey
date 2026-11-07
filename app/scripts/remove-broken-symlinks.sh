#!/usr/bin/env bash
# 删除 app 包内断开或循环的符号链接并输出被删除的路径。
# sherpa-onnx 的 onnxruntime.framework 会带入 Versions/A/A -> A;codesign 严格校验和公证无法处理这类链接。
set -euo pipefail

root="${1:?用法: remove-broken-symlinks.sh <app 路径>}"
while IFS= read -r -d '' link; do
    if [[ ! -e "${link}" ]]; then
        printf '%s\n' "${link}"
        rm -f "${link}"
    fi
done < <(find "${root}" -type l -print0)
