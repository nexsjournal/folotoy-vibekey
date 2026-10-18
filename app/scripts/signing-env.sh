# 签名 / 公证凭据(被 build-signed.sh、release.sh、install.sh 用 source 引入,不单独运行)。
#
# 凭据来源(仓库公开,凭据一律不进仓库):
#   1. 环境变量 DEVELOPER_ID、NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER(或 NOTARY_PROFILE);
#   2. 没设置的,从本机的 app/Config/Release.local.env 读取(已在 .gitignore 里),格式:
#        DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#        NOTARY_KEY=/path/to/AuthKey_XXXXXXXXXX.p8
#        NOTARY_KEY_ID=XXXXXXXXXX
#        NOTARY_ISSUER=<issuer-uuid>
#   环境变量优先于文件(方便临时换证书)。
#
# 引入后提供:DEVELOPER_ID、team(证书里的 Team ID);调用 load_notary_args 后得到 notary_args 数组。
# 调用方需先 cd 到 app/。

source scripts/local-env.sh
signing_local_env="${local_env_file}"

: "${DEVELOPER_ID:?请设置 DEVELOPER_ID(环境变量或 ${signing_local_env}),例如 \"Developer ID Application: Your Name (TEAMID)\"}"
team="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"${DEVELOPER_ID}")"
[[ -n "${team}" ]] || { echo "DEVELOPER_ID 末尾应带 (TEAMID)" >&2; exit 1; }

# 公证参数:notarytool 保存的钥匙串配置(NOTARY_PROFILE)或 App Store Connect API Key 三件套。
load_notary_args() {
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        notary_args=(--keychain-profile "${NOTARY_PROFILE}")
    else
        : "${NOTARY_KEY:?请设置 NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER(或 NOTARY_PROFILE),也可写进 ${signing_local_env}}"
        : "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER:?}"
        notary_args=(--key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER}")
    fi
}
