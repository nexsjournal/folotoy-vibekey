#!/usr/bin/env bash
# 部署 InputBetter 官网到 0os 服务器(共享 Caddy 反向代理 + *.0os.io 证书),做法与服务器上其他站点一致:
#   website/deploy/deploy.sh <user@host> [ssh-key] [dmg]
# - dmg 默认取 app/build/release/ 里最新的 InputBetter-*.dmg(由 app/scripts/release.sh 生成并公证);
# - 在本机临时目录组装站点:复制 website/site,放入 DMG,把页面里的 {{VERSION}} {{SIZE}} {{SHA256}} {{DMG_URL}} 换成实际值;
# - 同步到服务器 /opt/inputbetter-web,重建 inputbetter-web 容器,安装 input.0os.io.caddy,校验并重载 Caddy;
# - 最后请求线上首页和安装包确认可用。
# 服务器地址和密钥都从参数传入,不写进仓库。
set -euo pipefail

target="${1:?usage: website/deploy/deploy.sh <user@host> [ssh-key] [dmg]}"
key="${2:-}"
ssh_opts=(-o ConnectTimeout=20)
[[ -n "${key}" ]] && ssh_opts+=(-i "${key}")
remote_dir=/opt/inputbetter-web
site_file=input.0os.io.caddy
domain=input.0os.io
cd "$(dirname "$0")/../.."

dmg="${3:-$(ls -t app/build/release/InputBetter-*.dmg 2>/dev/null | head -1)}"
[[ -f "${dmg}" ]] || { echo "找不到 DMG,请先运行 app/scripts/release.sh" >&2; exit 1; }
xcrun stapler validate "${dmg}" >/dev/null || { echo "${dmg} 没有公证票据,请用 release.sh 完成公证后再发布" >&2; exit 1; }
file_name="$(basename "${dmg}")"
version="${file_name#InputBetter-}"; version="${version%.dmg}"
size="$(awk -v b="$(stat -f%z "${dmg}")" 'BEGIN { printf "%.0f MB", b / 1000000 }')"
sha="$(shasum -a 256 "${dmg}" | awk '{print $1}')"

stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT
cp -R website/site "${stage}/site"
cp -R website/deploy "${stage}/deploy"
mkdir -p "${stage}/site/download"
cp "${dmg}" "${stage}/site/download/${file_name}"
echo "${sha}" > "${stage}/site/download/${file_name}.sha256"
for f in "${stage}/site/index.html" "${stage}/site/assets/main.js"; do
    sed -i '' -e "s|{{VERSION}}|${version}|g" -e "s|{{SIZE}}|${size}|g" -e "s|{{SHA256}}|${sha}|g" \
        -e "s|{{DMG_URL}}|/download/${file_name}|g" "${f}"
done
echo "==> Site for InputBetter ${version} (${size}) assembled"

ssh "${ssh_opts[@]}" "${target}" 'test -f /opt/proxy/docker-compose.yml || { echo "The shared proxy is missing." >&2; exit 1; }
  docker network inspect web >/dev/null 2>&1 || { echo "The web network is missing." >&2; exit 1; }'
ssh "${ssh_opts[@]}" "${target}" "mkdir -p ${remote_dir}"
rsync -az --delete -e "ssh ${ssh_opts[*]}" --exclude .DS_Store "${stage}/" "${target}:${remote_dir}/"
ssh "${ssh_opts[@]}" "${target}" "set -e
  cd ${remote_dir}/deploy
  docker compose up -d --build --remove-orphans
  install -m 644 ${site_file} /opt/proxy/caddy/sites/${site_file}
  docker compose -f /opt/proxy/docker-compose.yml exec -T caddy caddy validate --config /etc/caddy/Caddyfile
  docker compose -f /opt/proxy/docker-compose.yml exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  docker image prune -f >/dev/null
  docker compose ps"

echo "==> Verifying https://${domain}/"
for i in 1 2 3 4 5 6; do
    if curl -fsS -o /dev/null "https://${domain}/"; then break; fi
    sleep 5
done
curl -fsS "https://${domain}/" | grep -q "${sha}" || { echo "首页没有显示新版本" >&2; exit 1; }
curl -fsSI "https://${domain}/download/${file_name}" | grep -iE "^HTTP|content-length"
echo "Deployed https://${domain}/  (download: /download/${file_name})"
