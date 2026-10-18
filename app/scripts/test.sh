#!/usr/bin/env bash
# 运行单元测试(协议编解码、ADPCM、按键状态机、文本处理、LLM 解析等),以及本地包 AppUpdateKit 的测试(检查更新)。
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project InputBetter.xcodeproj -scheme InputBetter -configuration Debug \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' test | grep -E "error:|Executed|TEST" || true
# AppUpdateKit 是独立的 Swift 包,用 swift test 单独跑(构建目录放在 build/ 下,不留在包目录里)。
swift test --package-path Packages/AppUpdateKit --scratch-path build/AppUpdateKit 2>&1 | grep -E "error:|✘|Test run" || true
