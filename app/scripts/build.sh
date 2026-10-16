#!/usr/bin/env bash
# 生成 Xcode 工程并编译 app,产物复制到 app/build/InputBetter.app。
#   CONFIGURATION=Debug ./scripts/build.sh   编译 Debug(默认 Release)
#   SIGN_IDENTITY=- ./scripts/build.sh        没有开发证书时改用 ad-hoc 签名(每次编译后需重新授权辅助功能)
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-Release}"
derived="build/DerivedData"
# 打包烧录工具 esptool(引导页一键刷固件用;固件本身刷写时从官网下载)。第一次需要联网,失败不影响编译。
./scripts/bundle-device-assets.sh || echo "warning: esptool 打包失败,app 里将无法刷固件" >&2
xcodegen generate --quiet
settings=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then settings+=(CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"); fi
xcodebuild -project InputBetter.xcodeproj -scheme InputBetter -configuration "${configuration}" \
    -derivedDataPath "${derived}" -destination 'platform=macOS' ${settings[@]+"${settings[@]}"} build | grep -E "error:|warning:|BUILD" || true
rm -rf build/InputBetter.app
cp -R "${derived}/Build/Products/${configuration}/InputBetter.app" build/InputBetter.app
echo "Built $(pwd)/build/InputBetter.app"
