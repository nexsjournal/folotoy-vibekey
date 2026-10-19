# 官网与安装包发布

官网:<https://input.0os.io>。源码在 `website/`,安装包由 `app/scripts/release.sh` 生成。

## 目录

| 路径 | 内容 |
| --- | --- |
| `website/site/index.html` | 首页:一屏不滚动,导航 / 页脚 / 版心和另外两页一致。中间是两个真实场景(没有外框):听写时是一个「笔记」窗口,文字落进光标处;实时字幕时先演示入口:光标点开胶囊的工具条 → 在应用列表里选 Chrome → Chrome / YouTube 视频窗口出现(说话人头像、声波、播放进度),字幕条再浮到视频上:说话人在左侧(不被字幕条盖住),原文逐词出现,译文一行行往上滚(保留三行,越旧越暗)。听写和字幕两个场景循环播放,按住 / 点一下胶囊可以自己玩一遍。标语、下载 / GitHub 按钮始终在,底下一行版本与系统要求,页脚里放 Passport 入口 |
| `website/site/passport/index.html` | Passport 页(可选的配套硬件):设备轮播(真实固件截图,鼠标移上去轻微倾斜)、功能卡片、按键表、规格、`#firmware` 网页刷写区;文案明确"没有硬件 app 也完整可用",入口主要给极客用户 |
| `website/site/support/index.html` | 支持页:一句话 → 留言表单(全页唯一的留言入口,`POST /api/support`,相对路径,由服务器转发到后台;蜜罐防垃圾)→ 常见问题;内容列(760)左对齐到和 Passport / 首页同一个版心,页脚是安装包版本与 SHA-256 |
| `website/site/assets/style.css`、`main.js` | 三页共用:色彩令牌、背景(点阵 + 冷光)、导航、按钮、页脚、滚动浮现、跟随指针的柔光、顶部阅读进度;中英文切换(`IB.i18n`)。`main.js` 把旧链接 `/#firmware` 转到 `/passport/#firmware` |
| `website/site/assets/home.*`、`passport.*`、`support.*` | 各页自己的布局、动画与英文词条 |
| `website/site/assets/passport/*.png` | 设备屏幕截图,由 `firmware/tools/ui-preview/run.sh` 生成后无损压成调色板 PNG(每张 3–10 KB) |
| `website/site/assets/flasher.js` | Passport 网页刷写(Web Serial + esptool-js),见下文「Passport 固件」 |
| `website/site/assets/vendor/esptool-js-0.7.0.js` | Espressif 官方 [esptool-js](https://github.com/espressif/esptool-js) 0.7.0 的 `bundle.js` 原样拷贝(Apache-2.0,许可证同目录),本站自带,不走 CDN |
| `website/deploy/Dockerfile`、`nginx.conf` | 只服务静态文件的 nginx 容器(非 root,8080,不记录访问日志) |
| `website/deploy/docker-compose.yml` | 容器 `inputbetter-web`,接入服务器上共享的 `web` 网络 |
| `website/deploy/input.0os.io.caddy` | 共享 Caddy 的站点配置(`*.0os.io` 证书、公共安全头、HSTS),反代到 `inputbetter-web:8080` |
| `website/deploy/deploy.sh` | 部署脚本 |
| `website/preview.py` | 本地预览:替换页面占位符、把 `/download/` 与 `/firmware/` 映射到本机产物,全部 `no-store`;改完文件刷新就能看,不用先打包 |

页面里的 `{{VERSION}}`、`{{SIZE}}`、`{{SHA256}}`、`{{DMG_URL}}` 是占位符,部署时按实际的 DMG 替换(首页用 `{{VERSION}}`、`{{DMG_URL}}`、`{{SIZE}}`,支持页页脚用 `{{VERSION}}`、`{{SHA256}}`;`deploy.sh` 的线上校验:首页的下载链接是新安装包、支持页有新 SHA-256)。部署时页面里引用的 `/assets/*.css`、`*.js` 会加上内容哈希 `?v=…`(assets 长缓存,文件一改地址就变,浏览器不会用旧样式 / 脚本配新页面)。中文写在 HTML 里(`data-i18n` 元素的文本就是中文原文),英文在各页脚本通过 `IB.i18n.add` 注册的字典里;默认跟随浏览器语言,可手动切换并记在 localStorage。动画都用原生 CSS / JS,尊重「减少动态效果」;不加载任何外部资源(esptool-js 也放在本站)。

首页演示的尺寸、字号、圆角都照 app 的胶囊来(`app/InputBetter/Pill`):空闲细条 36×6、录音胶囊高 34、波形 92×22、实时文字气泡 13.5/430、字幕条宽 570(默认 17/19 字号下 app 的 `maxWidth`)、圆角 18、内边距 20 / 上 9(有标题栏 10)/ 下 11;原文 17×2 行、译文 19×3 行(行距 3.8,亮度按新旧 1 / 0.82 / 0.68);标题栏只在前 1.8 s 和鼠标悬停时显示,和其他时候只有字幕,和 app 的悬停行为一致。改 app 的胶囊外观时记得同步 `home.css`。三页共用同一个导航、页脚和版心。

CSS 里不要用 `font: … inherit` 这种简写(`inherit` 不能作为简写的字体族,整条声明会被浏览器丢掉,字号会退回 16px);用 `font-size` / `font-weight` / `line-height` 分开写。

本地预览:

```bash
website/preview.py            # http://127.0.0.1:8788/;--port 换端口,--open 自动打开浏览器
```

它把页面里的占位符换成 `app/build/release` 里最新 DMG 的实际值,并把 `/download/`、`/firmware/` 映射到本机的 `app/build/release`、`firmware/build/release`,全部 `no-store`,改完文件刷新即可。没有 DMG / 固件时用占位值,下载链接指向线上。留言表单在本地会得到 501,线上由反向代理把 `/api/support` 转发到后台(后台不在本仓库)。

## 打包安装包(签名 + 公证)

```bash
cd app
DEVELOPER_ID="Developer ID Application: <姓名> (<TEAMID>)" \
NOTARY_KEY=<AuthKey_XXXXXXXXXX.p8 路径> NOTARY_KEY_ID=<Key ID> NOTARY_ISSUER=<Issuer ID> \
./scripts/release.sh
```

- 也可以用 notarytool 保存的钥匙串配置:`NOTARY_PROFILE=<名称>` 代替三个 `NOTARY_*`。
- 凭据也可以写进本机的 `app/Config/Release.local.env`(已在 .gitignore 中,格式见 `app/scripts/signing-env.sh`),之后直接运行脚本即可;环境变量优先于文件。
- 流程(编译签名部分在 `build-signed.sh`,和 `install.sh` 共用):Release 构建(Developer ID 签名、Hardened Runtime、`--timestamp`、去掉 get-task-allow)→ 修复 sherpa-onnx 的 `onnxruntime.framework` 里断开 / 循环的符号链接并由内到外重签 → 按 Sparkle 文档由内到外重签 Sparkle 的 Installer.xpc / Downloader.xpc(保留 entitlements)/ Autoupdate / Updater.app / 框架 → 重签 app → `codesign --verify --deep --strict` → DMG → 签名 → `notarytool submit --wait` → `stapler staple` → `spctl` 校验 → 生成 `.sha256` → Sparkle `sign_update` 对最终 DMG 做 EdDSA 签名并校验,写入 `.sparkle`(签名与字节数)。
- DMG 安装窗口用 [dmgbuild](https://github.com/dmgbuild/dmgbuild)(固定版本,`scripts/dmg/ensure-dmgbuild.sh` 装在 `app/build/tools` 的独立虚拟环境里)直接写 `.DS_Store`,不依赖 Finder 脚本:窗口 600×360、128 px 图标,app 与「应用程序」左右排开;背景由 `scripts/dmg/background.swift` 生成(浅色底 + 一条细箭头,不放文字——Finder 在自定义背景图上总用深色画文件名;1x / 2x 合成 Retina TIFF),配置在 `scripts/dmg/settings.py`。
- 检查更新接口在本机 `app/Config/Update.local.xcconfig` 配置(见 README「官网版与开源版」);`release.sh` 会打印编进 app 的接口地址,没配置时给出警告。
- Sparkle 的 EdDSA 私钥用 Sparkle `generate_keys` 生成,存在发布者本机的登录钥匙串里(另有一份导出备份,只在本机);公钥写在 `Update.local.xcconfig` 的 `IB_UPDATE_PUBLIC_ED_KEY`。私钥丢失后已安装的 app 无法再在 app 内更新,务必备份。也可以用 `SPARKLE_KEY_FILE=<导出的私钥文件>` 代替钥匙串。
- 第三方的 `esptool` 保留 Espressif 自己的 Developer ID 签名,不重签。
- 产物在 `app/build/release/`(已在 .gitignore 中),不提交到仓库。
- 发版前记得改 `app/project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。

## 本机安装正式版(自测)

```bash
cd app && ./scripts/install.sh
```

- 和发布版走同样的签名、公证(提交 zip,票据 staple 到 app 上),只是不打包 DMG;然后正常退出正在运行的 InputBetter(10 秒没退再强制结束),替换 `/Applications/InputBetter.app` 并启动。
- `SKIP_NOTARIZE=1` 只签名不公证(本机编译的 app 没有隔离属性,也能打开);`NO_LAUNCH=1` 装好后不启动。
- 签名证书和之前装的版本不同时(如之前是 Xcode 的 Apple Development 签名),系统会当成另一个 app,麦克风 / 辅助功能 / 屏幕录制权限需要重新授权。

## Passport 固件

app 不内置固件,app 和网页刷写都从官网 `/firmware/` 下载同一份:

```
/firmware/manifest.json                 清单:version、build(app.bin 0xB0 起 4 字节,与设备 hello 一致)、proto、chip、images[]
/firmware/<version>-<build>/bootloader.bin   0x0
/firmware/<version>-<build>/partition-table.bin   0x8000
/firmware/<version>-<build>/app.bin     0x10000
```

- 由 `scripts/package-firmware.sh` 从 `firmware/build` 生成(到 `firmware/build/release/`),`deploy.sh` 每次部署都会重新生成并发布。脚本检查镜像地址与 `build/flash_args` 一致、写入范围都在 `cardid`(0x356000)之前,并给每个镜像算 SHA-256。
- 清单里不放 esptool 参数,只有地址、大小和校验值;app(`FirmwareManifest`)和网页(`flasher.js`)用同样的规则校验:芯片 ESP32-C3、地址 < 0x356000、不重叠、路径只能是清单目录下的相对路径。
- `proto` 与 app 的协议版本不一致时,app 不刷,提示先更新 app。
- 缓存:`manifest.json` 不缓存,发布后立即生效;镜像目录带版本和构建标识,长缓存。

网页刷写(`/passport/#firmware`)没有用 ESP Web Tools:它在「全新安装」时默认擦除整片 Flash(勾选询问时用户也可能选擦除),会抹掉 Passport 的设备身份数据。`flasher.js` 只做 app 里同样的事:

1. 点击后选择串口(VID 0x303A);
2. 下载清单和镜像,校验大小与 SHA-256;
3. 连接下载模式,确认芯片 ESP32-C3、Flash 8 MB、分区表里有 `cardid@0x356000`,否则停止;
4. 可选(默认勾选)先读出整片 8 MB 存成 `passport-<MAC>-flash.bin`;
5. `writeFlash` 只写清单里的三段(`eraseAll: false`,flash 参数 `keep`),然后硬复位。

需要桌面版 Chrome / Edge(Web Serial),页面必须是 HTTPS;InputBetter app 会独占串口,网页刷写前要先退出它。

## 部署

```bash
website/deploy/deploy.sh <user@host> <ssh-key> [dmg]
```

- dmg 默认取 `app/build/release/` 里最新的;没有公证票据的 DMG 会被拒绝发布。
- 脚本先运行 `scripts/package-firmware.sh`(需要已编译的 `firmware/build`),然后在本机临时目录组装站点(放入 DMG、`.sha256` 和 `firmware/`,替换占位符),同步到服务器 `/opt/inputbetter-web`,重建容器,把 `input.0os.io.caddy` 安装到 `/opt/proxy/caddy/sites/`,校验并重载 Caddy,最后请求线上首页、安装包和固件清单确认可用。
- 服务器上的共享代理(`/opt/proxy`)、`web` 网络、`*.0os.io` 证书和其他站点都不改动;做法与同机的其他站点一致。
- 安装包按附件下载,文件名带版本号,可长缓存;首页不缓存,发版后立即生效。

## 发布更新(通知已安装的用户)

```bash
cd app && ./scripts/publish-update.sh [--required-at-or-below <版本> | --no-required]
```

在 `release.sh` 和 `deploy.sh` 之后运行。脚本先确认官网上的 DMG 与本地 SHA-256 一致,再把版本号、构建号、最低系统版本、Sparkle 签名与大小,以及 `docs/releases/<版本>.zh.md` / `.en.md` 的更新说明登记到更新后台(0os Console 的「版本更新」,按平台保存)。已安装的 app 每天检查一次 `input.0os.io/api/update`,有新版本时弹窗;用户点「下载并安装」后 Sparkle 从 `input.0os.io/api/appcast.xml` 取 appcast,下载 DMG、校验 EdDSA 签名与代码签名后替换并重启。

- 「版本 ≤ X 必须更新」默认保留后台现有设置;`--required-at-or-below` 设新值,`--no-required` 取消。也可以在后台网页或 MCP 工具 `set_app_update` 里改。
- 后台地址、API 密钥、应用标识只在本机 `app/Config/Release.local.env`(`UPDATE_CONSOLE_URL`、`UPDATE_CONSOLE_KEY_FILE`、`UPDATE_APP_ID`、`UPDATE_DOWNLOAD_BASE`)。
- 官网把 `/api/support`(留言)、`/api/update`、`/api/appcast.xml` 反向代理到后台。这段 Caddy 路由只在本机 `website/deploy/private/routes.caddy`(已在 .gitignore 中),`deploy.sh` 部署时把它插进 `input.0os.io.caddy` 的标记处;没有这个文件时这三个接口返回 404。安装新站点配置前会备份旧配置,`caddy validate` 不通过就恢复,避免影响同机其他站点。

## 不提交的内容

服务器地址、SSH 密钥、Developer ID 证书、公证用的 App Store Connect API 密钥、Sparkle EdDSA 私钥、更新接口与后台地址(`Update.local.xcconfig`、`Release.local.env`、`deploy/private/`)都只在本机,运行脚本时作为参数或环境变量传入,不写进仓库。DMG 不提交到仓库,也不发 GitHub Release,只放在官网。
