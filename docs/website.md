# 官网与安装包发布

官网:<https://input.0os.io>。源码在 `website/`,安装包由 `app/scripts/release.sh` 生成。

## 目录

| 路径 | 内容 |
| --- | --- |
| `website/site/` | 静态页面:`index.html`、`assets/style.css`、`assets/main.js`(中英文切换、滚动浮现、听写 / 双语字幕演示动画)、图标 |
| `website/deploy/Dockerfile`、`nginx.conf` | 只服务静态文件的 nginx 容器(非 root,8080,不记录访问日志) |
| `website/deploy/docker-compose.yml` | 容器 `inputbetter-web`,接入服务器上共享的 `web` 网络 |
| `website/deploy/input.0os.io.caddy` | 共享 Caddy 的站点配置(`*.0os.io` 证书、公共安全头、HSTS),反代到 `inputbetter-web:8080` |
| `website/deploy/deploy.sh` | 部署脚本 |

页面里的 `{{VERSION}}`、`{{SIZE}}`、`{{SHA256}}`、`{{DMG_URL}}` 是占位符,部署时按实际的 DMG 替换。中文写在 HTML 里,英文在 `main.js` 的 `en` 字典中;默认跟随浏览器语言,可手动切换。动画都用原生 CSS / JS,尊重「减少动态效果」;不加载任何外部资源。

本地预览:把 `website/site` 复制到临时目录、替换占位符后用 `python3 -m http.server` 打开(`deploy.sh` 里的组装步骤可以照抄)。

## 打包安装包(签名 + 公证)

```bash
cd app
DEVELOPER_ID="Developer ID Application: <姓名> (<TEAMID>)" \
NOTARY_KEY=<AuthKey_XXXXXXXXXX.p8 路径> NOTARY_KEY_ID=<Key ID> NOTARY_ISSUER=<Issuer ID> \
./scripts/release.sh
```

- 也可以用 notarytool 保存的钥匙串配置:`NOTARY_PROFILE=<名称>` 代替三个 `NOTARY_*`。
- 流程:Release 构建(Developer ID 签名、Hardened Runtime、`--timestamp`、去掉 get-task-allow)→ 修复 sherpa-onnx 的 `onnxruntime.framework` 里断开 / 循环的符号链接并由内到外重签 → `codesign --verify --deep --strict` → DMG(app + 应用程序快捷方式)→ 签名 → `notarytool submit --wait` → `stapler staple` → `spctl` 校验 → 生成 `.sha256`。
- 第三方的 `esptool` 保留 Espressif 自己的 Developer ID 签名,不重签。
- 产物在 `app/build/release/`(已在 .gitignore 中),不提交到仓库。
- 发版前记得改 `app/project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。

## 部署

```bash
website/deploy/deploy.sh <user@host> <ssh-key> [dmg]
```

- dmg 默认取 `app/build/release/` 里最新的;没有公证票据的 DMG 会被拒绝发布。
- 脚本在本机临时目录组装站点(放入 DMG 和 `.sha256`,替换占位符),同步到服务器 `/opt/inputbetter-web`,重建容器,把 `input.0os.io.caddy` 安装到 `/opt/proxy/caddy/sites/`,校验并重载 Caddy,最后请求线上首页和安装包确认可用。
- 服务器上的共享代理(`/opt/proxy`)、`web` 网络、`*.0os.io` 证书和其他站点都不改动;做法与同机的其他站点一致。
- 安装包按附件下载,文件名带版本号,可长缓存;首页不缓存,发版后立即生效。

## 不提交的内容

服务器地址、SSH 密钥、Developer ID 证书、公证用的 App Store Connect API 密钥都只在本机,运行脚本时作为参数或环境变量传入,不写进仓库。DMG 不提交到仓库,也不发 GitHub Release,只放在官网。
