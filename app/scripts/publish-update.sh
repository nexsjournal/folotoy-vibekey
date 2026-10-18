#!/usr/bin/env bash
# 把刚发布的版本登记到更新后台,已安装的 app 下次检查时就会提示更新(并能用 Sparkle 在 app 内安装)。
#   ./scripts/publish-update.sh [--required-at-or-below <版本>] [--no-required]
#
# 先运行 release.sh(生成 DMG、.sha256、.sparkle)和 website/deploy/deploy.sh(把 DMG 放到官网)。
# 本脚本会:
#   1. 确认官网上的 DMG 与本地 SHA-256 一致(没上线或不一致就停止,免得用户下载到别的文件);
#   2. 读取版本号、构建号、最低系统版本、Sparkle 签名与大小,以及 docs/releases/<版本>.zh.md / .en.md 的更新说明;
#   3. PUT 到 0os Console 的 /v1/admin/updates/macos(后台接口格式见其 docs/api.md)。
# 「版本 ≤ X 必须更新」默认保留后台现有的设置;--required-at-or-below 改成新值,--no-required 取消强制。
#
# 地址与密钥只在本机(app/Config/Release.local.env,或环境变量;仓库公开,不写进来):
#   UPDATE_CONSOLE_URL=https://<后台地址>
#   UPDATE_CONSOLE_KEY_FILE=<后台 API 密钥文件路径>(或直接 UPDATE_CONSOLE_KEY=…)
#   UPDATE_APP_ID=<后台里的应用标识>
#   UPDATE_DOWNLOAD_BASE=https://<官网>/download
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/local-env.sh

required_mode=keep required_value=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --required-at-or-below) required_mode=set; required_value="${2:?}"; shift 2 ;;
        --no-required) required_mode=clear; shift ;;
        *) echo "未知参数:$1" >&2; exit 2 ;;
    esac
done

: "${UPDATE_CONSOLE_URL:?请在 Config/Release.local.env 设置 UPDATE_CONSOLE_URL}"
: "${UPDATE_APP_ID:?请设置 UPDATE_APP_ID}"
: "${UPDATE_DOWNLOAD_BASE:?请设置 UPDATE_DOWNLOAD_BASE}"
key="${UPDATE_CONSOLE_KEY:-}"
if [[ -z "${key}" && -n "${UPDATE_CONSOLE_KEY_FILE:-}" ]]; then key="$(tr -d '[:space:]' < "${UPDATE_CONSOLE_KEY_FILE/#\~/${HOME}}")"; fi
[[ -n "${key}" ]] || { echo "请设置 UPDATE_CONSOLE_KEY 或 UPDATE_CONSOLE_KEY_FILE" >&2; exit 1; }

version="$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)"
build="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([^"]+)"?$/\1/p' project.yml | head -1)"
minimum="$(sed -nE 's/^ *MACOSX_DEPLOYMENT_TARGET: *"?([^"]+)"?$/\1/p' project.yml | head -1)"
dmg="build/release/InputBetter-${version}.dmg"
[[ -f "${dmg}" && -f "${dmg}.sha256" ]] || { echo "找不到 ${dmg},请先运行 release.sh" >&2; exit 1; }
[[ -f "${dmg}.sparkle" ]] || { echo "缺少 ${dmg}.sparkle(Sparkle 签名),请用 release.sh 重新打包" >&2; exit 1; }
signature="$(sed -nE 's/.*edSignature="([^"]+)".*/\1/p' "${dmg}.sparkle")"
length="$(sed -nE 's/.*length="([0-9]+)".*/\1/p' "${dmg}.sparkle")"
[[ "${length}" == "$(stat -f%z "${dmg}")" ]] || { echo ".sparkle 与 DMG 大小不一致,请重新签名" >&2; exit 1; }
url="${UPDATE_DOWNLOAD_BASE%/}/$(basename "${dmg}")"

echo "==> Checking ${url}"
remote_sha="$(curl -fsSL "${url}" | shasum -a 256 | awk '{print $1}')"
[[ "${remote_sha}" == "$(cat "${dmg}.sha256")" ]] || { echo "官网上的 DMG 与本地不一致(或还没部署),先运行 website/deploy/deploy.sh" >&2; exit 1; }

notes_zh="docs/releases/${version}.zh.md"; notes_en="docs/releases/${version}.en.md"
[[ -f "../${notes_zh}" && -f "../${notes_en}" ]] || { echo "请先写更新说明:${notes_zh} 和 ${notes_en}" >&2; exit 1; }

api="${UPDATE_CONSOLE_URL%/}/v1/admin/updates"
auth=(-H "Authorization: Bearer ${key}" -H "X-App-ID: ${UPDATE_APP_ID}")
current="$(curl -fsS "${auth[@]}" "${api}")"
body="$(python3 - "${current}" "${required_mode}" "${required_value}" "${version}" "${build}" "${url}" "${length}" "${signature}" "${minimum}" "../${notes_zh}" "../${notes_en}" <<'PY'
import json, sys
current, mode, value, version, build, url, length, signature, minimum, zh, en = sys.argv[1:]
existing = next((u for u in json.loads(current)["updates"] if u["platform"] == "macos"), None)
required = {"keep": (existing or {}).get("requiredAtOrBelow", ""), "set": value, "clear": ""}[mode]
print(json.dumps({"version": version, "build": build, "url": url, "length": int(length), "edSignature": signature,
                  "minimumSystemVersion": minimum, "requiredAtOrBelow": required,
                  "notes": {"zh": open(zh).read().strip(), "en": open(en).read().strip()}}, ensure_ascii=False))
PY
)"
echo "==> Publishing InputBetter ${version} (${build}) to the update feed"
curl -fsS -X PUT "${auth[@]}" -H "Content-Type: application/json" --data-binary "${body}" "${api}/macos" \
    | python3 -c 'import json,sys; u=json.load(sys.stdin); print("Published", u["version"], "build", u["build"], "· required ≤", u["requiredAtOrBelow"] or "—")'
