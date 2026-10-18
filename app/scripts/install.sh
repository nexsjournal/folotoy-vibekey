#!/usr/bin/env bash
# 编译正式版 app(Developer ID 签名 + 公证 + staple),替换 /Applications/InputBetter.app 并启动——本机自测用。
# 和官网下载的版本走同样的签名、公证流程,只是不打包 DMG(发布用 release.sh)。
#
# 用法(凭据见 signing-env.sh,写进 app/Config/Release.local.env 后直接运行即可):
#   ./scripts/install.sh
#   SKIP_NOTARIZE=1 ./scripts/install.sh   只签名不公证,省几分钟(本机编译的 app 没有隔离属性,也能正常打开)
#   NO_LAUNCH=1 ./scripts/install.sh       装好后不启动
#
# 注意:签名证书和之前装的版本不同时(如从 Xcode 的 Apple Development 换成 Developer ID),
# 系统会把它当成另一个 app,麦克风 / 辅助功能 / 屏幕录制等权限需要重新授权。
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/signing-env.sh
# 先检查公证凭据,免得编译完才发现缺少。
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then load_notary_args; fi
./scripts/build-signed.sh
app="build/ReleaseDerivedData/Build/Products/Release/InputBetter.app"
target="/Applications/InputBetter.app"
bundle_id="$(defaults read "$(pwd)/${app}/Contents/Info.plist" CFBundleIdentifier)"

# ---- 公证(提交 zip,票据钉到 app 上,离线也能通过 Gatekeeper)----
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    zip="$(mktemp -d)/InputBetter.zip"
    trap 'rm -rf "$(dirname "${zip}")"' EXIT
    ditto -c -k --keepParent "${app}" "${zip}"
    echo "==> Notarizing (this usually takes a few minutes)"
    xcrun notarytool submit "${zip}" "${notary_args[@]}" --wait --timeout 60m
    xcrun stapler staple "${app}"
    echo "==> Gatekeeper check"
    spctl --assess --type execute --verbose=2 "${app}"
fi

# ---- 退出正在运行的旧版本 ----
if pgrep -xq InputBetter; then
    echo "==> Quitting running InputBetter"
    # 先正常退出(让 app 走 applicationShouldTerminate,保存设置、释放音频设备);10 秒还没退再强制结束。
    osascript -e "tell application id \"${bundle_id}\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -xq InputBetter || break; sleep 0.5; done
    if pgrep -xq InputBetter; then
        echo "    still running, killing"
        pkill -x InputBetter || true
        sleep 1
    fi
fi

# ---- 替换 /Applications 里的 app ----
# 先复制到同目录的临时位置,再删旧换新,避免复制到一半时 /Applications 里留下残缺的 app。
echo "==> Installing to ${target}"
staging="${target%.app}.installing.app"
rm -rf "${staging}"
ditto "${app}" "${staging}"
rm -rf "${target}"
mv "${staging}" "${target}"
codesign --verify --deep --strict "${target}"
echo "Installed $(defaults read "${target}/Contents/Info.plist" CFBundleShortVersionString) ($(defaults read "${target}/Contents/Info.plist" CFBundleVersion)) → ${target}"

if [[ -z "${NO_LAUNCH:-}" ]]; then open "${target}"; fi
