# 读取本机的 app/Config/Release.local.env(已在 .gitignore 里;仓库公开,凭据和地址一律不进仓库)。
# 被 signing-env.sh、publish-update.sh 用 source 引入,不单独运行;调用方需先 cd 到 app/。
# 逐行读取 KEY=VALUE,只填补没有设置的变量:环境变量优先于文件(方便临时覆盖)。
local_env_file="Config/Release.local.env"
if [[ -f "${local_env_file}" ]]; then
    while IFS='=' read -r key value; do
        [[ "${key}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ -n "${!key:-}" ]] && continue
        value="${value%\"}"; value="${value#\"}"
        export "${key}=${value}"
    done < "${local_env_file}"
fi
