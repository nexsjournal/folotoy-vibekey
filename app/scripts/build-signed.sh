#!/usr/bin/env bash
# 编译 Release 并用 Developer ID 签名(Hardened Runtime + 安全时间戳),供 release.sh(打包 DMG)和 install.sh(装到本机)共用。
# 凭据见 signing-env.sh。产物:app/build/ReleaseDerivedData/Build/Products/Release/FoloVibe Key.app。
# 第三方的 esptool 保留 Espressif 自己的 Developer ID 签名(已带 Hardened Runtime 与时间戳),不重签。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/package-lock-guard.sh
source scripts/signing-env.sh

version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)"
derived="build/ReleaseDerivedData"
app="${derived}/Build/Products/Release/FoloVibe Key.app"

# 打包烧录工具 esptool(发布版必须带上,否则用户无法在 app 里刷固件);固件本身刷写时从官网下载。
./scripts/bundle-device-assets.sh
xcodegen generate --quiet
echo "==> Building FoloVibe Key ${version} (Release, ${DEVELOPER_ID})"
rm -rf "${app}"
set +e
xcodebuild -project VibeKey.xcodeproj -scheme VibeKey -configuration Release \
    -derivedDataPath "${derived}" -destination 'platform=macOS' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${DEVELOPER_ID}" DEVELOPMENT_TEAM="${team}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    clean build | grep -E "error:|BUILD|CodeSign .*failed"
build_pipeline_status=("${PIPESTATUS[@]}")
set -e
build_status="${build_pipeline_status[0]}"
[[ -x "${app}/Contents/MacOS/FoloVibe Key" ]] || {
    echo "构建失败: 未生成可执行文件 (xcodebuild exit ${build_status})" >&2
    exit 1
}
if (( build_status != 0 )); then
    echo "==> xcodebuild exit ${build_status}; repairing embedded signatures before final verification"
fi
# 测试包不随 app 分发。
rm -rf "${app}/Contents/PlugIns/VibeKeyTests.xctest"

# sherpa-onnx 的 onnxruntime.framework 里带了一个指向自己的符号链接(Versions/A/A -> A),
# codesign 严格校验时报 "Too many levels of symbolic links",公证也会失败。
broken="$(scripts/remove-broken-symlinks.sh "${app}")"
if [[ -n "${broken}" ]]; then
    echo "==> Removing broken / looping symlinks:"
    echo "${broken}"
    for framework in "${app}"/Contents/Frameworks/*.framework; do
        codesign --force --sign "${DEVELOPER_ID}" --timestamp --options runtime "${framework}"
    done
fi

# Sparkle(应用内更新)的 XPC 服务、Autoupdate、Updater.app 在 Swift 包里是 ad-hoc 签名,
# 按 Sparkle 文档(Documentation › Sandboxing / Code Signing)由内到外用 Developer ID 重签,否则公证不通过;
# Downloader.xpc 保留自带的 entitlements。
sparkle="${app}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${sparkle}" ]]; then
    echo "==> Signing Sparkle helpers"
    sign() { codesign --force --sign "${DEVELOPER_ID}" --timestamp --options runtime "$@"; }
    sign "${sparkle}/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "${sparkle}/Versions/B/XPCServices/Downloader.xpc"
    sign "${sparkle}/Versions/B/Autoupdate"
    sign "${sparkle}/Versions/B/Updater.app"
    sign "${sparkle}"
fi

# 改过内嵌代码后最后重签 app 本身(保留原有的标识、权限声明和标志)。
if [[ -n "${broken}" || -d "${sparkle}" ]]; then
    codesign --force --sign "${DEVELOPER_ID}" --timestamp --options runtime \
        --preserve-metadata=identifier,entitlements,requirements,flags "${app}"
fi

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "${app}"
codesign -dvv "${app}" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime|Timestamp" || {
    echo "签名缺少 Developer ID / Hardened Runtime / 时间戳" >&2; exit 1; }
echo "Signed: $(pwd)/${app}"
