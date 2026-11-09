# FoloVibe Key

FoloVibe Key：全面的 AI 语音指令助手。macOS 本地语音输入 app，配套 FoloToy AI Passport 硬件。默认所有语音识别都在本机完成，也可以接入自己的云端识别服务。

仓库:<https://github.com/nexsjournal/folotoy-vibekey>

FoloVibe Key 基于 [InputBetter](https://github.com/racall/InputBetter) 提交 `ab1fd9f3e7a1c0a6cbb04533c07829845ddc9b0b` 派生,沿用上游 MIT 许可与开发规范。上游版权、第三方组件许可见 [LICENSE](LICENSE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

为兼容已经安装的版本,内部标识仍沿用 `local.folobutton.dev`(Bundle ID)、`folobutton-dev://`(URL scheme)、`_folobutton._tcp`(mDNS)和 `FoloButtonDev`(数据目录)。这些是升级兼容标识,不是产品名;改名会让系统权限、hooks 和本机数据失效。

- **听写**:按住快捷键(默认 ⌥ 空格,可改)说话,松开后文字输入到当前光标处。也可以短按开始、再按一次结束。翻译 / 润色失败时会输入原文并用警告色说明原因,点一下可以打开 设置 › 听写。
- **实时字幕**:选一个应用(例如 Chrome 里播放的 YouTube),把它的声音实时转成字幕。底部的状态胶囊会展开成可拖动的字幕条(拖丢了可以在菜单里点「状态条回到底部中央」,或在 设置 › 快捷键 给它设一个快捷键)。可选双语翻译。
  - 字幕条采用同传类应用的滚动字幕:原文跟着语音实时走;译文边说边译,正在说的半句先给出暂定译文(略暗),说完一句后换成整句译文,只比原文慢零点几秒,不丢句。识别结果先经 LocalAgreement 稳定化再断句。
  - 译文每句单独起一行，最新的一句最亮、越早的越暗，滚动时平滑移动，不会读着读着找不到位置；还没读完就滚走了，可以像 Apple Music 歌词一样在译文上往回滚动，停几秒后自动回到最新；译文行数（2–5）和翻译时原文行数（可不显示）可在 设置 › 实时字幕 调整。
  - 每场字幕默认不翻译。鼠标悬停时显示工具栏:点「译」就翻译成默认语言(设置 › 实时字幕 › 默认翻译成),再点一次关闭;「译」旁的箭头可以换语言;旁边的翻译方式标签可以随时切换系统翻译、在线翻译服务或 AI 模型;「原文 N 行」标签可以快速调整翻译时原文显示几行(或只看译文)。原文和译文字号分别可调。字幕条锁定(鼠标穿透)后,翻译的开关、语言和方式也可以在菜单栏 / 状态条 ⌃ 菜单的「实时字幕」里操作。翻译中途出错(如额度用完)会在字幕条上常驻说明原因。
  - 字幕记录窗口(进行中或结束后)可以单独翻译:在「翻译」菜单里选一个语言就开始翻译;⋯ 里可以全部重新翻译、用 AI 润色译文,也可以隐藏译文。
  - 字幕条上的「字幕记录」可以查看本场的全部字幕,拷贝或保存成文本文件;记录窗口可以固定在屏幕右侧,半透明并始终置顶。记录窗口的「总结」页可以让 AI 每隔几分钟总结一次刚才的内容(接口用设置里配置的服务,模型可另选;只在显示这一页并打开开关时总结,关窗口自动暂停)。
  - 结束字幕前在字幕条的 ⏹ 上弹出小气泡确认一次(可关闭,不弹模态框),结束后自动打开字幕记录窗口,可以在那里查看、总结(分段 / 全文)和保存。app 不保存字幕历史,记录只在内存里。
- **Passport 硬件**(右侧从上到下:上键 / 下键 / OK 键,屏幕右边的提示贴着对应按键):
  - USB、BLE 或同一局域网 Wi‑Fi 连接；首次通过 USB 在 设置 › Passport 配置 2.4 GHz Wi‑Fi，显示无线就绪后可拔线；最多保存 4 个网络。首次添加新网络须通过 USB；已经保存的网络可在设备离线时长按 ▼，用上下键选择，短按 OK 切换；
  - 设置 › Passport › 连接状态显示当前链路、最后在线、固件 build、电量和充电电压；Agent 导航可逐个检测 Codex、DeepSeek、WorkBuddy、ZCode、Claude 等是否能读到项目和会话；
  - 离线页背景可换：设置 › Passport › 离线页背景选一张照片，Mac 会自动裁成 240×320、做绿色像素化和上下暗带，再经 USB / Wi-Fi 写入设备；不调用生图模型，也不上传原图。恢复默认可随时回到内置像素猫；
  - 按住 OK 立即采音，同时自动前置并聚焦记住的目标应用（默认 Codex），松开后输入识别或翻译结果;
  - 上键安全发送当前 Codex 输入框中的手动／语音草稿,下键停止当前 Codex 任务(默认值;也可在 设置 › Passport › 按键 改成普通快捷键);
  - 长按上键切换模式;
  - 长按下键打开「应用 / 项目 / 会话」导航:普通应用直接切换;Codex、DeepSeek Honeycomb、ZCode、Claude、WorkBuddy 以及其他带聊天输入框 + 侧栏的 Agent 会先选项目、再选会话,选中后打开对话并把光标放回输入框,可以直接按住 OK 说话、上键发送。

  Claude Code / Codex 完成或需要确认时,设备会响铃提醒。专为 vibe coding 设计。
- **界面语言**:简体中文 / English / 跟随系统(设置 › 通用),切换即时生效。
- **检查更新**:官网版每天自动检查一次新版本(设置 › 通用 › 关于与更新,或菜单「检查更新…」);开源版可配置自己的更新接口,见「官网版与开源版」。
- **翻译**:实时字幕和听写翻译各自选择翻译方式和目标语言(设置 › 实时字幕 / 设置 › 听写;服务在 设置 › 翻译服务 里配置),可选:
  - 系统翻译:macOS 自带的离线翻译,免费、最快,语言包可在引导或设置里一键下载;
  - 在线机器翻译:DeepL、Google 翻译、微软翻译、火山引擎、腾讯云、百度翻译(填自己的密钥,各家都有免费额度);
  - AI 大模型:结合上下文修正识别错误,译文最通顺,可以在字幕条上直接换模型。
  - 目标语言默认「自动」(中文用户:中文 → English,其他语言 → 中文)。
- **AI 服务**(可选,任意 OpenAI 兼容接口,设置 › AI 服务):接口和 Key 配置一次,听写后润色、AI 翻译、字幕总结各自选模型。填好地址和 Key 后自动拉取模型列表供选择。
- **设置按场景组织**:听写(润色、听写翻译)、实时字幕(字幕用的识别模型、显示、行数、翻译、字幕记录)、识别模型(下载与云端识别配置)、翻译服务(语言包与在线服务密钥)、AI 服务(LLM 接口)。

## 识别模型

| 模型 | 大小 | 说明 |
| --- | --- | --- |
| Whisper Large v3 Turbo(压缩版) | 约 650 MB | 默认,多语言高准确率 |
| SenseVoice Small | 约 240 MB | 中文极快,自带标点 |
| Apple Speech | 系统管理 | 原生流式,字幕延迟最低 |
| Whisper Large v3 Turbo | 约 1.6 GB | 完整版 |
| Whisper Small | 约 490 MB | 轻量 |

本机实测(M 系列 Mac,8.5 秒中文、4.4 秒英文语音,"松开到出字"的时间):

- SenseVoice 约 0.1–0.2 秒。
- Whisper Turbo 压缩版约 0.5–1.5 秒。
- 第一次加载 Whisper 时,CoreML 要为本机芯片优化模型,约 2–3 分钟,以后约 1.6 秒。

### 云端识别(可选,自备 API Key)

在 设置 › 模型 › 云端识别 里配置后,听写和字幕都可以使用。听写和字幕可以各选一个模型,本地或云端都行。

| 服务 | 方式 | 特点 |
| --- | --- | --- |
| 火山引擎 · 豆包流式识别 2.0 | WebSocket 流式 | 普通话准确率高,中英混说、方言;中国大陆 |
| 阿里云百炼 · Fun-ASR 实时识别 | WebSocket 流式 | 方言覆盖广;中国大陆 / 国际两个区域 |
| ElevenLabs Scribe v2 Realtime | WebSocket 流式 | 国际服务,中英粤准确率高、延迟低 |
| [Soniox](https://soniox.com) 实时识别(stt-rt-v5) | WebSocket 流式 | 国际服务,约 60 种语言、中英混说,延迟低;模型列表从接口获取 |
| OpenAI 兼容转写接口 | 按句上传 | OpenAI、Groq 等 `/audio/transcriptions` |

- API Key(包括 AI 后处理的 Key)只保存在本机文件 `~/Library/Application Support/FoloButtonDev/credentials.json`,权限 0600,不使用钥匙串。
- 使用云端识别时,录音会发送到对应服务商。

## 目录

| 路径 | 内容 |
| --- | --- |
| `app/` | macOS app,Swift 6 / SwiftUI,用 XcodeGen 生成工程,要求 macOS 26+ |
| `app/Packages/AppUpdateKit/` | 检查更新(独立 Swift 包,可复用),见下文「官网版与开源版」 |
| `firmware/` | Passport 固件,ESP-IDF 5.5.3 / LVGL 9,见 `firmware/README.md` |
| `docs/protocol.md` | 设备通信协议 |
| `docs/device-ui.md` | 设备界面与交互设计 |
| `docs/changelogs/` | 每次修改的记录 |
| `website/` | 官网(静态页面与部署脚本),见 `docs/website.md` |

## 编译运行

官网源码已改为 VibeKey,当前线上仍部署在 <https://input.0os.io>(域名未迁移;按 `docs/website.md` 重新部署后生效)。安装包由 `app/scripts/release.sh` 生成并公证(macOS 26+,Apple 芯片)。也可以自行编译;上游要求 Xcode 27,本分支在 Xcode 26.2 与 XcodeGen 下构建通过。

默认 ad-hoc 签名。想让重新编译后辅助功能权限不失效,可以新建 `app/Config/Signing.local.xcconfig`(已在 .gitignore 中)填入自己的开发证书:

```
CODE_SIGN_IDENTITY = Apple Development: Your Name (XXXXXXXXXX)
DEVELOPMENT_TEAM = YOURTEAMID
```

配置后 `./scripts/build.sh` 会沿用该证书，不再在复制产物后覆盖成 ad-hoc 签名。

```bash
cd app
./scripts/build.sh            # 产物:app/build/FoloVibe Key.app
./scripts/test.sh             # 单元测试
open "build/FoloVibe Key.app"
```

有 Developer ID 证书时,`./scripts/install.sh` 会编译签名公证正式版、替换 `/Applications/FoloVibe Key.app` 并启动(自测用,凭据配置见 [docs/website.md](docs/website.md))。

编译、测试、打包之后想恢复干净目录:仓库根目录运行 `./scripts/clean.sh`(删除 app 与固件的全部产物;`--keep-downloads` 保留需联网下载的 esptool 与 ESP-IDF 组件,`--dry-run` 只列出不删)。

第一次启动会进入引导,依次是:

1. 授予麦克风与辅助功能权限
2. 下载模型
3. 设置快捷键
4. 翻译与 AI(可选,可一键下载系统翻译语言、连接 AI)
5. 连接 Passport(可选,可一键刷固件、设置 Passport 麦克风)
6. 试一试

## 官网版与开源版(检查更新)

两者的代码完全相同,区别只在本机配置:

| | 官网下载的版本 | 自行编译的开源版 |
| --- | --- | --- |
| 检查更新 | 每天自动检查一次,也可在 设置 › 通用 › 关于与更新 或菜单「检查更新…」手动检查;有新版本时弹窗显示更新内容,点「下载并安装」在 app 内完成更新(Sparkle);发布方可要求低于某个版本的必须更新 | 默认没有配置更新接口,不检查更新,也不显示检查入口 |
| 更新接口 | 官网的接口(地址只在发布者本机配置,不在仓库里) | 可以配置自己的接口 |

检查更新的逻辑在本地 Swift 包 `app/Packages/AppUpdateKit`(与 VibeKey 无关,可以拷到其他 app 复用):`AppUpdateKit` 负责版本比较、每 24 小时检查一次、跳过此版本 / 稍后提醒、强制更新,以及解析 JSON 更新数据的 `JSONUpdateFeed`;`AppUpdateInstaller` 用 [Sparkle 2](https://sparkle-project.org)(macOS 官网分发 app 的业内标准)下载、校验签名并安装,进度显示在 app 自己的更新窗口里。

**给开源版配置自己的更新接口**:新建 `app/Config/Update.local.xcconfig`(已在 .gitignore 中),写入

```
IB_UPDATE_FEED_URL = https:/$()/example.com/vibekey/update.json
IB_UPDATE_APP_ID = vibekey    // 可选,作为 X-App-ID 请求头发送
```

(xcconfig 里 `//` 是注释,URL 的双斜杠要写成 `/$()/`。)重新编译后生效。app 会 GET 这个地址(自动加上 `?platform=macos`),返回如下 JSON;可以是任何服务器接口,也可以直接放一个静态文件:

```json
{
  "latest": {
    "version": "1.2.0",
    "build": "42",
    "notes": {"zh": "- 新增……", "en": "- New…"},
    "url": "https://example.com/FoloVibe-Key-1.2.0.dmg"
  },
  "requiredAtOrBelow": "1.0.3"
}
```

- `latest` 为 `null` 表示没有可用版本;`build`、`notes`、`requiredAtOrBelow` 可省略;`url` 必须是 HTTPS,「下载更新」会在浏览器里打开它。
- 当前版本 ≤ `requiredAtOrBelow` 时必须更新(提示窗口只能下载或退出)。
- 调试构建可以用 `IB_UPDATE_DEMO=available|required` 查看更新提示的界面(不联网),`IB_UPDATE_FEED=<url>` 临时换接口。

**在 app 内下载安装(可选,Sparkle 2)**:只配置上面的接口时,「下载更新」会在浏览器里打开安装包、由用户手动替换。想像官网版一样在 app 内下载、校验并自动安装重启,再配置 Sparkle 的 appcast 和 EdDSA 公钥:

1. 用 Sparkle 自带的工具生成密钥(私钥存进本机钥匙串,公钥打印出来;编译过一次后工具在 `app/build/**/artifacts/sparkle/Sparkle/bin/`):`generate_keys`,并用 `generate_keys -x <文件>` 备份私钥。
2. 在 `Update.local.xcconfig` 里加上:

   ```
   IB_UPDATE_APPCAST_URL = https:/$()/example.com/vibekey/appcast.xml
   IB_UPDATE_PUBLIC_ED_KEY = <generate_keys 打印的公钥>
   ```

3. 发版时用 `sign_update <dmg>` 得到 `sparkle:edSignature` 和 `length`,写进 appcast(格式见 [Sparkle 文档](https://sparkle-project.org/documentation/publishing/);`sparkle:version` 填构建号 CFBundleVersion)。`release.sh` 会自动签名并把结果写进 `build/release/*.sparkle`。

Sparkle 会校验下载文件的 EdDSA 签名和新 app 的代码签名,两者都通过才安装。

## 烧录 Passport 固件

app 不内置固件,刷写时从官网下载最新固件([input.0os.io/firmware/manifest.json](https://input.0os.io/firmware/manifest.json)),下载后逐个校验 SHA-256。

**在 app 里一键刷入(推荐)**:

- 位置:引导的「连接 Passport」一步,或 设置 › Passport;设置页会显示官网是否有新固件。
- `build.sh` 会用 `scripts/bundle-device-assets.sh` 把烧录工具 esptool 打包进 app。
- 第一次刷某台设备前,app 会把整片 Flash 备份到 `~/Library/Application Support/FoloButtonDev/Backups/`。

**在官网用浏览器刷入**:用电脑上的 Chrome / Edge 打开 [input.0os.io/passport/](https://input.0os.io/passport/#firmware),先退出 VibeKey app,点「连接并刷入」。可选先把整片 Flash 备份下载到本机。网页会检查芯片、Flash 大小和 `cardid` 分区,不是 Passport 就停止。

也可以用命令行:

```bash
./scripts/flash-firmware.sh
```

- 第一次烧录某台设备前,脚本会把整片 Flash 备份到 `~/esp/passport-backups/`。
- 烧录前请先退出 VibeKey。

三种方式都只写 bootloader、分区表和应用,不擦除整片 Flash,绝不写 `cardid` 分区。

发布新固件:编译固件后运行 `website/deploy/deploy.sh`,它会调用 `scripts/package-firmware.sh` 生成清单和镜像并发布到官网,app 和网页随即可以刷到新版本。

## Vibe Coding 通知

在 设置 › Vibe Coding 里对 Claude Code 和 Codex 分别点「一键配置」:

- Claude Code:写入 `~/.claude/settings.json` 的 hooks。
- Codex:写入 `~/.codex/hooks.json` 或原位升级旧完成 Hook。首次配置或命令升级后，在终端运行 `codex`，用 `/hooks` 审查并信任新版 `Stop`。
- Codex 本轮结束后,Passport 显示 `DONE / OK OPEN`。短按 OK 或点击 Mac 通知可打开原对话,等 `READY TO TALK` 后按住 OK 说话,松开形成草稿,短按上键发送。完成卡显示 15 秒。

首次配置时原文件会备份为 `.folobutton-dev.bak`。已有其他 Hook 配置保留。

## 本地化

- 源语言是简体中文。
- 英文翻译在 `app/Localization/en.json`,按界面语境翻译。
- 改了界面文字后运行 `app/scripts/update-strings.sh`,重新生成 `Localizable.xcstrings`;缺少翻译时脚本会列出来。

## 参考项目

VibeKey 参考了以下开源项目的设计与做法(未复制其代码):

- [betterwispr](https://github.com/opennookorg/betterwispr):状态胶囊条、按应用采集系统声音、粘贴输入。
- [MemoEcho](https://github.com/isecret/MemoEcho):SenseVoice 接入、首次引导、剪贴板恢复。
