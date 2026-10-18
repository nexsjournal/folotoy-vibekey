#!/usr/bin/env bash
# 运行单元测试(协议编解码、ADPCM、按键状态机、文本处理、LLM 解析等),以及本地包 AppUpdateKit 的测试(检查更新)。
# 任一测试失败脚本以非 0 退出(发版前用它做门禁)。
set -euo pipefail
cd "$(dirname "$0")/.."
# 工程把 DeviceAssets(esptool)整个目录打进 Resources,干净检出 / 清理后目录不存在会导致链接失败,和 build.sh 一样先准备好。
./scripts/bundle-device-assets.sh || echo "warning: esptool 打包失败,app 里将无法刷固件" >&2
xcodegen generate --quiet
# 只显示关键行,但退出码取 xcodebuild / swift test 自己的(grep 匹配与否不影响)。
set +e
xcodebuild -project InputBetter.xcodeproj -scheme InputBetter -configuration Debug \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' test 2>&1 \
    | grep -E "error:|Executed|TEST|failed"
status=${PIPESTATUS[0]}
# AppUpdateKit 是独立的 Swift 包,用 swift test 单独跑(构建目录放在 build/ 下,不留在包目录里)。
swift test --package-path Packages/AppUpdateKit --scratch-path build/AppUpdateKit 2>&1 \
    | grep -E "error:|✘|Test run"
pkg_status=${PIPESTATUS[0]}
set -e
if [[ ${status} -ne 0 || ${pkg_status} -ne 0 ]]; then
    echo "TESTS FAILED (app=${status}, AppUpdateKit=${pkg_status})" >&2
    exit 1
fi
