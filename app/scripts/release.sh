#!/usr/bin/env bash
# 打包可分发的 DMG(官网下载用),按 Apple 对 App Store 以外分发的要求:
#   Developer ID 签名 + Hardened Runtime + 安全时间戳 → DMG → 签名 → 公证(notarytool)→ staple → Gatekeeper 校验。
#
# 用法(凭据见 signing-env.sh:环境变量,或本机的 app/Config/Release.local.env):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_KEY=/path/to/AuthKey_XXXXXXXXXX.p8 NOTARY_KEY_ID=XXXXXXXXXX NOTARY_ISSUER=<issuer-uuid> \
#   ./scripts/release.sh
# 也可以用 notarytool 保存的钥匙串配置代替三个 NOTARY_* 变量:NOTARY_PROFILE=<名称>。
# SKIP_NOTARIZE=1 只签名打包、不公证(仅本机测试,别人下载后会被 Gatekeeper 拦下)。
#
# 产物:app/build/release/InputBetter-<版本>.dmg 和同名 .sha256、.sparkle(EdDSA 签名与大小,应用内安装用)。
# 发布:website/deploy/deploy.sh 上传到官网,再用 scripts/publish-update.sh 通知已安装的用户更新。
# 编译与签名在 build-signed.sh(和 install.sh 共用)。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing-env.sh
# 先检查公证凭据,免得编译完才发现缺少。
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then load_notary_args; fi

version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)"
out="build/release"
app="build/ReleaseDerivedData/Build/Products/Release/InputBetter.app"
dmg="${out}/InputBetter-${version}.dmg"

# ---- 构建并签名 ----
./scripts/build-signed.sh

# 检查更新接口来自本机的 Config/Update.local.xcconfig(不在仓库里);没配置时这个版本不会提示用户更新。
feed="$(/usr/libexec/PlistBuddy -c 'Print :IBUpdateFeedURL' "${app}/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "${feed}" ]]; then echo "==> Update feed: ${feed}"; else echo "warning: 未配置检查更新接口(Config/Update.local.xcconfig),这个版本不会检查更新" >&2; fi

# ---- DMG ----
# 安装窗口(背景、图标位置、窗口大小)用 dmgbuild 直接写进 .DS_Store,不依赖 Finder 脚本;配置见 scripts/dmg/。
echo "==> Creating ${dmg}"
mkdir -p "${out}"
staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT
swift scripts/dmg/background.swift "${staging}" >/dev/null
tiffutil -cathidpicheck "${staging}/background.png" "${staging}/background@2x.png" -out "${staging}/background.tiff" >/dev/null 2>&1
dmgbuild="$(scripts/dmg/ensure-dmgbuild.sh)"
rm -f "${dmg}"
"${dmgbuild}" -s scripts/dmg/settings.py -D app="${app}" -D background="${staging}/background.tiff" \
    "InputBetter ${version}" "${dmg}" 2>&1 | grep -v "hdiutil: WARNING" || true
[[ -f "${dmg}" ]] || { echo "DMG 生成失败" >&2; exit 1; }
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

# ---- Sparkle 签名(应用内安装时校验更新包)----
# 必须在 staple 之后签:签名覆盖的是最终发布的 DMG 字节。私钥默认取本机钥匙串(Sparkle generate_keys 生成),
# 也可以用 SPARKLE_KEY_FILE 指定导出的私钥文件。结果写进同名 .sparkle,publish-update.sh 发布时读取。
sign_update="$(find build -path '*artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)"
if [[ -n "${sign_update}" ]]; then
    key_args=(); [[ -n "${SPARKLE_KEY_FILE:-}" ]] && key_args=(--ed-key-file "${SPARKLE_KEY_FILE}")
    "${sign_update}" ${key_args[@]+"${key_args[@]}"} "${dmg}" > "${dmg}.sparkle"
    signature="$(sed -nE 's/.*edSignature="([^"]+)".*/\1/p' "${dmg}.sparkle")"
    "${sign_update}" ${key_args[@]+"${key_args[@]}"} --verify "${dmg}" "${signature}" >/dev/null
    echo "==> Sparkle signature: $(cat "${dmg}.sparkle")"
else
    echo "warning: 没找到 Sparkle 的 sign_update,这个 DMG 不能在 app 内安装" >&2
fi
echo "Done: $(pwd)/${dmg}"
echo "SHA-256: $(cat "${dmg}.sha256")"
