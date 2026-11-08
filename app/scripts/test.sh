#!/usr/bin/env bash
# 运行单元测试(协议编解码、ADPCM、按键状态机、文本处理、LLM 解析等),以及本地包 AppUpdateKit 的测试(检查更新)。
# 任一测试失败脚本以非 0 退出(发版前用它做门禁)。
set -euo pipefail
cd "$(dirname "$0")/.."

# Xcode 的 app-hosted unit test 偶尔会留下 PPID 1 的测试宿主，并让 LaunchServices
# 延迟再次启动同一 bundle ID。测试前后清理进程并注销测试 App，再明确登记正式 App。
test_app="$PWD/build/DerivedData/Build/Products/Debug/FoloVibe Key.app"
test_host="${test_app}/Contents/MacOS/FoloVibe Key"
release_app="$PWD/build/FoloVibe Key.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
cleanup_test_host() {
    for pid in $(pgrep -f -- "${test_host}" 2>/dev/null || true); do
        command="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
        [[ "${command}" == "${test_host}" ]] && kill "${pid}" 2>/dev/null || true
    done
}
cleanup_test_registration() {
    cleanup_test_host
    [[ -d "${test_app}" ]] && "${lsregister}" -u "${test_app}" >/dev/null 2>&1 || true
    [[ -d "${release_app}" ]] && "${lsregister}" -f "${release_app}" >/dev/null 2>&1 || true
}
cleanup_test_registration
trap cleanup_test_registration EXIT

# 工程把 DeviceAssets(esptool)整个目录打进 Resources,干净检出 / 清理后目录不存在会导致链接失败,和 build.sh 一样先准备好。
./scripts/bundle-device-assets.sh || echo "warning: esptool 打包失败,app 里将无法刷固件" >&2
xcodegen generate --quiet
# 只显示关键行,但退出码取 xcodebuild / swift test 自己的(grep 匹配与否不影响)。
set +e
xcodebuild -project VibeKey.xcodeproj -scheme VibeKey -configuration Debug \
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
