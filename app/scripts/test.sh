#!/usr/bin/env bash
# 运行单元测试(协议编解码、ADPCM、按键状态机、文本处理、LLM 解析等)。
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project InputBetter.xcodeproj -scheme InputBetter -configuration Debug \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' test | grep -E "error:|Executed|TEST" || true
