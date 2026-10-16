#!/usr/bin/env bash
# 编译 Debug 提取字符串,再生成 Localizable.xcstrings(见 update-strings.py)。
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project InputBetter.xcodeproj -scheme InputBetter -configuration Debug \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' build | grep -E "error:|BUILD" || true
python3 scripts/update-strings.py
