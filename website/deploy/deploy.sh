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
# 所有页面和脚本里的占位符都替换(首页、Passport、支持页共用下载信息)。
while IFS= read -r -d '' f; do
    sed -i '' -e "s|{{VERSION}}|${version}|g" -e "s|{{SIZE}}|${size}|g" -e "s|{{SHA256}}|${sha}|g" \
        -e "s|{{DMG_URL}}|/download/${file_name}|g" "${f}"
done < <(find "${stage}/site" \( -name '*.html' -o -name '*.js' \) -not -path '*/vendor/*' -print0)
# 静态资源加内容指纹:页面里引用的 /assets/*.css、*.js 改成 ?v=<内容哈希前 10 位>。
# assets 是长缓存(nginx max-age 1 天),文件一改地址就变,浏览器不会拿旧样式 / 脚本配新页面。
while IFS= read -r -d '' asset; do
    rel="/assets/${asset#"${stage}/site/assets/"}"
    hash="$(shasum -a 256 "${asset}" | cut -c1-10)"
    find "${stage}/site" -name '*.html' -exec sed -i '' -e "s|\"${rel}\"|\"${rel}?v=${hash}\"|g" {} +
done < <(find "${stage}/site/assets" -maxdepth 1 \( -name '*.css' -o -name '*.js' \) -print0)
# 反向代理到后台的路由只在本机(website/deploy/private/routes.caddy,不在仓库里),替换 Caddy 配置里的标记行。
caddy_file="${stage}/deploy/${site_file}"
if [[ -f website/deploy/private/routes.caddy ]]; then
    python3 - "${caddy_file}" website/deploy/private/routes.caddy <<'PY'
import sys
site, routes = sys.argv[1], open(sys.argv[2]).read().rstrip("\n") + "\n"
text = open(site).read()
lines = text.splitlines(keepends=True)
i = next(n for n, line in enumerate(lines) if "@private-routes" in line)
lines.insert(i, routes)
open(site, "w").write("".join(lines))
PY
else
    echo "warning: 没有 website/deploy/private/routes.caddy,官网留言和检查更新接口不可用" >&2
fi
rm -rf "${stage}/deploy/private"
echo "==> Site for InputBetter ${version} (${size}) assembled"

ssh "${ssh_opts[@]}" "${target}" 'test -f /opt/proxy/docker-compose.yml || { echo "The shared proxy is missing." >&2; exit 1; }
  docker network inspect web >/dev/null 2>&1 || { echo "The web network is missing." >&2; exit 1; }'
ssh "${ssh_opts[@]}" "${target}" "mkdir -p ${remote_dir}"
rsync -az --delete -e "ssh ${ssh_opts[*]}" --exclude .DS_Store "${stage}/" "${target}:${remote_dir}/"
ssh "${ssh_opts[@]}" "${target}" "set -e
  cd ${remote_dir}/deploy
  docker compose up -d --build --remove-orphans
  # 先备份旧的站点配置,新配置校验不过就恢复,免得共享 Caddy 下次重载时影响同机的其他站点。
  sites=/opt/proxy/caddy/sites
  [ -f \${sites}/${site_file} ] && cp \${sites}/${site_file} /tmp/${site_file}.previous
  install -m 644 ${site_file} \${sites}/${site_file}
  if ! docker compose -f /opt/proxy/docker-compose.yml exec -T caddy caddy validate --config /etc/caddy/Caddyfile; then
    if [ -f /tmp/${site_file}.previous ]; then cp /tmp/${site_file}.previous \${sites}/${site_file}; fi
    echo 'Caddy 配置校验失败,已恢复原配置' >&2; exit 1
  fi
  docker compose -f /opt/proxy/docker-compose.yml exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  docker image prune -f >/dev/null
  docker compose ps"

echo "==> Verifying https://${domain}/"
for i in 1 2 3 4 5 6; do
    if curl -fsS -o /dev/null "https://${domain}/"; then break; fi
    sleep 5
done
curl -fsS "https://${domain}/" | grep -q "/download/${file_name}" || { echo "首页的下载按钮不是新版本" >&2; exit 1; }
curl -fsS "https://${domain}/support/" | grep -q "${sha}" || { echo "支持页没有显示新版本的 SHA-256" >&2; exit 1; }
curl -fsSI "https://${domain}/download/${file_name}" | grep -iE "^HTTP|content-length"
curl -fsS "https://${domain}/firmware/manifest.json" | grep -q "\"build\": \"${fw_build}\"" || { echo "线上固件清单不是 ${fw_build}" >&2; exit 1; }
echo "Firmware ${fw_build}: https://${domain}/firmware/manifest.json"
if [[ -f website/deploy/private/routes.caddy ]]; then
    curl -fsS "https://${domain}/api/update?platform=macos" | grep -q '"platform":"macos"' || { echo "检查更新接口不可用" >&2; exit 1; }
    echo "Update feed OK: https://${domain}/api/update"
fi
echo "Deployed https://${domain}/  (download: /download/${file_name})"
