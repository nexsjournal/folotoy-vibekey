#!/usr/bin/env bash
# 生成 Xcode 工程并编译 app,产物复制到 app/build/FoloVibe Key.app。
#   CONFIGURATION=Debug ./scripts/build.sh   编译 Debug(默认 Release)
#   SIGN_IDENTITY=- ./scripts/build.sh        没有开发证书时改用 ad-hoc 签名(每次编译后需重新授权辅助功能)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/package-lock-guard.sh
configuration="${CONFIGURATION:-Release}"
derived="build/DerivedData"

# 本地未显式传 SIGN_IDENTITY 时沿用 Signing.local.xcconfig。否则即使 Xcode 已用固定证书签名，
# 后面的 ad-hoc 深签名仍会覆盖它，导致辅助功能授权在每次重建后失效。
sign_identity="${SIGN_IDENTITY:-}"
if [[ -z "${sign_identity}" && -f Config/Signing.local.xcconfig ]]; then
    sign_identity="$(sed -nE \
        's/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' \
        Config/Signing.local.xcconfig | tail -1)"
fi
sign_identity="${sign_identity:--}"

# 打包烧录工具 esptool(引导页一键刷固件用;固件本身刷写时从官网下载)。第一次需要联网,失败不影响编译。
./scripts/bundle-device-assets.sh || echo "warning: esptool 打包失败,app 里将无法刷固件" >&2
xcodegen generate --quiet
settings=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${sign_identity}")
xcodebuild -project VibeKey.xcodeproj -scheme VibeKey -configuration "${configuration}" \
    -derivedDataPath "${derived}" -destination 'platform=macOS' ${settings[@]+"${settings[@]}"} build 2>&1 | grep -E "error:|warning:|BUILD"
# 失败时 set -o pipefail 会在这里退出,不能把中间产物当成可运行的 app。
test -x "${derived}/Build/Products/${configuration}/FoloVibe Key.app/Contents/MacOS/FoloVibe Key"
rm -rf "build/FoloVibe Key.app"
cp -R "${derived}/Build/Products/${configuration}/FoloVibe Key.app" "build/FoloVibe Key.app"
# SwiftPM 带入的 onnxruntime.framework 含指向自身的符号链接,codesign 严格校验会报链接层级过深。
# 所有本地构建都在统一签名前移除断链,避免把不可校验的产物复制到 build。
removed_symlinks="$(scripts/remove-broken-symlinks.sh "build/FoloVibe Key.app")"
if [[ -n "${removed_symlinks}" ]]; then
    echo "Removing broken / looping symlinks:"
    echo "${removed_symlinks}"
fi
# 本地 ad-hoc 构建由 Xcode 分别签名主程序和 SwiftPM framework 时,dyld 会拒绝不同签名的 Sparkle。
# 开发包在这里统一做一次深签名;固定证书只重签被移除符号链接影响的 framework 和外层 app,
# 避免覆盖 Sparkle 等已经由 Xcode 正确签名的嵌套组件。
if [[ "${sign_identity}" == "-" ]]; then
    codesign --force --deep --sign - "build/FoloVibe Key.app"
elif [[ -n "${removed_symlinks}" ]]; then
    resigned_frameworks=$'\n'
    while IFS= read -r link; do
        [[ "${link}" == *"/Contents/Frameworks/"*.framework/* ]] || continue
        framework="${link%%.framework/*}.framework"
        if [[ "${resigned_frameworks}" != *$'\n'"${framework}"$'\n'* ]]; then
            codesign --force --sign "${sign_identity}" --options runtime "${framework}"
            resigned_frameworks+="${framework}"$'\n'
        fi
    done <<<"${removed_symlinks}"
    codesign --force --sign "${sign_identity}" --options runtime \
        --preserve-metadata=identifier,entitlements,requirements,flags "build/FoloVibe Key.app"
fi
codesign --verify --deep --strict --verbose=2 "build/FoloVibe Key.app"
echo "Built $(pwd)/build/FoloVibe Key.app"
