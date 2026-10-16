#!/usr/bin/env bash
# 打包可分发的 DMG(官网下载用),按 Apple 对 App Store 以外分发的要求:
#   Developer ID 签名 + Hardened Runtime + 安全时间戳 → DMG → 签名 → 公证(notarytool)→ staple → Gatekeeper 校验。
#
# 用法(证书与公证凭据都从环境变量传入,不写进仓库):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_KEY=/path/to/AuthKey_XXXXXXXXXX.p8 NOTARY_KEY_ID=XXXXXXXXXX NOTARY_ISSUER=<issuer-uuid> \
#   ./scripts/release.sh
# 也可以用 notarytool 保存的钥匙串配置代替三个 NOTARY_* 变量:NOTARY_PROFILE=<名称>。
# SKIP_NOTARIZE=1 只签名打包、不公证(仅本机测试,别人下载后会被 Gatekeeper 拦下)。
#
# 产物:app/build/release/InputBetter-<版本>.dmg 和同名 .sha256。
# 第三方的 esptool 保留 Espressif 自己的 Developer ID 签名(已带 Hardened Runtime 与时间戳),不重签。
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?请设置 DEVELOPER_ID,例如 \"Developer ID Application: Your Name (TEAMID)\"}"
team="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"${DEVELOPER_ID}")"
[[ -n "${team}" ]] || { echo "DEVELOPER_ID 末尾应带 (TEAMID)" >&2; exit 1; }

notary_args=()
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        notary_args=(--keychain-profile "${NOTARY_PROFILE}")
    else
        : "${NOTARY_KEY:?请设置 NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER,或 NOTARY_PROFILE}"
        : "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER:?}"
        notary_args=(--key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER}")
    fi
fi

version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)"
derived="build/ReleaseDerivedData"
out="build/release"
app="${derived}/Build/Products/Release/InputBetter.app"
dmg="${out}/InputBetter-${version}.dmg"

# ---- 构建并签名 ----
# 固件已编译时打包进 app(引导里一键刷固件);没有编译过固件则跳过。
[[ -f ../firmware/build/flash_args ]] && ./scripts/bundle-device-assets.sh
xcodegen generate --quiet
echo "==> Building InputBetter ${version} (Release, ${DEVELOPER_ID})"
xcodebuild -project InputBetter.xcodeproj -scheme InputBetter -configuration Release \
    -derivedDataPath "${derived}" -destination 'platform=macOS' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${DEVELOPER_ID}" DEVELOPMENT_TEAM="${team}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    clean build | grep -E "error:|BUILD" || true
[[ -d "${app}" ]] || { echo "构建失败" >&2; exit 1; }
# 测试包不随 app 分发。
rm -rf "${app}/Contents/PlugIns/InputBetterTests.xctest"

# sherpa-onnx 的 onnxruntime.framework 里带了一个指向自己的符号链接(Versions/A/A -> A),
# codesign 严格校验时报 "Too many levels of symbolic links",公证也会失败。
# 删掉 app 里所有断开或循环的符号链接,再由内到外重新签名(先框架,后 app,app 保留原有的权限声明)。
broken="$(find "${app}" -type l | while IFS= read -r link; do [[ -e "${link}" ]] || echo "${link}"; done)"
if [[ -n "${broken}" ]]; then
    echo "==> Removing broken / looping symlinks:"
    echo "${broken}"
    while IFS= read -r link; do rm -f "${link}"; done <<<"${broken}"
    for framework in "${app}"/Contents/Frameworks/*.framework; do
        codesign --force --sign "${DEVELOPER_ID}" --timestamp --options runtime "${framework}"
    done
    codesign --force --sign "${DEVELOPER_ID}" --timestamp --options runtime \
        --preserve-metadata=identifier,entitlements,requirements,flags "${app}"
fi

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "${app}"
codesign -dvv "${app}" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime|Timestamp" || {
    echo "签名缺少 Developer ID / Hardened Runtime / 时间戳" >&2; exit 1; }

# ---- DMG ----
echo "==> Creating ${dmg}"
mkdir -p "${out}"
staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT
ditto "${app}" "${staging}/InputBetter.app"
ln -s /Applications "${staging}/Applications"
rm -f "${dmg}"
hdiutil create -volname "InputBetter ${version}" -srcfolder "${staging}" -fs HFS+ -format UDZO -ov "${dmg}" >/dev/null
codesign --force --sign "${DEVELOPER_ID}" --timestamp "${dmg}"

# ---- 公证 ----
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    echo "==> Notarizing (this usually takes a few minutes)"
    xcrun notarytool submit "${dmg}" "${notary_args[@]}" --wait --timeout 60m
    xcrun stapler staple "${dmg}"
    echo "==> Gatekeeper check"
    spctl --assess --type open --context context:primary-signature --verbose=2 "${dmg}"
fi

shasum -a 256 "${dmg}" | awk '{print $1}' > "${dmg}.sha256"
echo "Done: $(pwd)/${dmg}"
echo "SHA-256: $(cat "${dmg}.sha256")"
