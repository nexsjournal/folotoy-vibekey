#!/usr/bin/env bash
# 生成 Xcode 工程并编译 app,产物复制到 app/build/InputBetter.app。
#   CONFIGURATION=Debug ./scripts/build.sh   编译 Debug(默认 Release)
#   SIGN_IDENTITY=- ./scripts/build.sh        没有开发证书时改用 ad-hoc 签名(每次编译后需重新授权辅助功能)
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-Release}"
derived="build/DerivedData"
# 固件已编译时顺带打包进 app(一键刷固件);没有编译过固件则跳过。
[[ -f ../firmware/build/flash_args ]] && ./scripts/bundle-device-assets.sh
xcodegen generate --quiet
settings=()
if [[ -n "${SIGN_IDENTITY:-}" ]]; then settings+=(CODE_SIGN_IDENTITY="${SIGN_IDENTITY}"); fi
xcodebuild -project InputBetter.xcodeproj -scheme InputBetter -configuration "${configuration}" \
    -derivedDataPath "${derived}" -destination 'platform=macOS' ${settings[@]+"${settings[@]}"} build | grep -E "error:|warning:|BUILD" || true
rm -rf build/InputBetter.app
cp -R "${derived}/Build/Products/${configuration}/InputBetter.app" build/InputBetter.app
echo "Built $(pwd)/build/InputBetter.app"
