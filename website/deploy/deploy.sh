#!/usr/bin/env bash
# 部署 InputBetter 官网到 0os 服务器(共享 Caddy 反向代理 + *.0os.io 证书),做法与服务器上其他站点一致:
#   website/deploy/deploy.sh <user@host> [ssh-key] [dmg]
# - dmg 默认取 app/build/release/ 里最新的 InputBetter-*.dmg(由 app/scripts/release.sh 生成并公证);
# - 固件取 firmware/build 的编译产物,由 scripts/package-firmware.sh 整理成 /firmware/manifest.json + 带版本目录的镜像
#   (app 刷写和官网网页刷写都从这里下载;app 不再内置固件);
# - 在本机临时目录组装站点:复制 website/site,放入 DMG 和固件,把页面里的 {{VERSION}} {{SIZE}} {{SHA256}} {{DMG_URL}} 换成实际值;
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

# 固件:每次部署都重新整理一遍,保证清单与 firmware/build 一致(脚本内会检查写入地址不覆盖 cardid)。
scripts/package-firmware.sh
fw_build="$(python3 -c "import json; print(json.load(open('firmware/build/release/manifest.json'))['build'])")"

stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT
cp -R website/site "${stage}/site"
cp -R website/deploy "${stage}/deploy"
mkdir -p "${stage}/site/download"
cp "${dmg}" "${stage}/site/download/${file_name}"
echo "${sha}" > "${stage}/site/download/${file_name}.sha256"
cp -R firmware/build/release "${stage}/site/firmware"
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
curl -fsS "https://${domain}/firmware/manifest.json" | grep -q "\"build\": \"${fw_build}\"" || { echo "线上固件清单不是 ${fw_build}" >&2; exit 1; }
echo "Firmware ${fw_build}: https://${domain}/firmware/manifest.json"
echo "Deployed https://${domain}/  (download: /download/${file_name})"
