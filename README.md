# InputBetter

本地语音输入的 macOS app,配套 FoloToy AI Passport 硬件。默认所有语音识别都在本机完成,也可以接入自己的云端识别服务。

- **听写**:按住快捷键(默认 ⌥ 空格,可改)说话,松开后文字输入到当前光标处。也可以短按开始、再按一次结束。翻译 / 润色失败时会输入原文并用警告色说明原因,点一下可以打开 设置 › 听写。
- **实时字幕**:选一个应用(例如 Chrome 里播放的 YouTube),把它的声音实时转成字幕。底部的状态胶囊会展开成可拖动的字幕条(拖丢了可以在菜单里点「状态条回到底部中央」,或在 设置 › 快捷键 给它设一个快捷键)。可选双语翻译。
  - 字幕条采用同传类应用的滚动字幕:原文跟着语音实时走;译文边说边译,正在说的半句先给出暂定译文(略暗),说完一句后换成整句译文,只比原文慢零点几秒,不丢句。识别结果先经 LocalAgreement 稳定化再断句。
  - 译文每句单独起一行，最新的一句最亮、越早的越暗，滚动时平滑移动，不会读着读着找不到位置；还没读完就滚走了，可以像 Apple Music 歌词一样在译文上往回滚动，停几秒后自动回到最新；译文行数（2–5）和翻译时原文行数（可不显示）可在 设置 › 实时字幕 调整。
  - 每场字幕默认不翻译。鼠标悬停时显示工具栏:点「译」就翻译成默认语言(设置 › 实时字幕 › 默认翻译成),再点一次关闭;「译」旁的箭头可以换语言;旁边的翻译方式标签可以随时切换系统翻译、在线翻译服务或 AI 模型;「原文 N 行」标签可以快速调整翻译时原文显示几行(或只看译文)。原文和译文字号分别可调。字幕条锁定(鼠标穿透)后,翻译的开关、语言和方式也可以在菜单栏 / 状态条 ⌃ 菜单的「实时字幕」里操作。翻译中途出错(如额度用完)会在字幕条上常驻说明原因。
  - 字幕记录窗口(进行中或结束后)可以单独翻译:在「翻译」菜单里选一个语言就开始翻译;⋯ 里可以全部重新翻译、用 AI 润色译文,也可以隐藏译文。
  - 字幕条上的「字幕记录」可以查看本场的全部字幕,拷贝或保存成文本文件;记录窗口可以固定在屏幕右侧,半透明并始终置顶。记录窗口的「总结」页可以让 AI 每隔几分钟总结一次刚才的内容(接口用设置里配置的服务,模型可另选;只在显示这一页并打开开关时总结,关窗口自动暂停)。
  - 结束字幕前确认一次(可关闭),结束后自动打开字幕记录窗口,可以在那里查看、总结(分段 / 全文)和保存。app 不保存字幕历史,记录只在内存里。
- **Passport 硬件**(右侧从上到下:上键 / 下键 / OK 键,屏幕右边的提示贴着对应按键):
  - 按住 OK 说话;
  - 上键回车,下键 Esc(默认值;可在 设置 › Passport › 按键 改成 ⌫ 退格、⌦ Delete、⌘Z 撤销、Tab 等,说错了可以直接在设备上回退删除);
  - 长按上键切换模式;
  - 长按下键打开「切换应用」列表,选中后把 Mac 上该应用的窗口前置并聚焦。

  Claude Code / Codex 完成或需要确认时,设备会响铃提醒。专为 vibe coding 设计。
- **界面语言**:简体中文 / English / 跟随系统(设置 › 通用),切换即时生效。
- **翻译**:实时字幕和听写翻译各自选择翻译方式和目标语言(设置 › 实时字幕 / 设置 › 听写;服务在 设置 › 翻译服务 里配置),可选:
  - 系统翻译:macOS 自带的离线翻译,免费、最快,语言包可在引导或设置里一键下载;
  - 在线机器翻译:DeepL、Google 翻译、微软翻译、火山引擎、腾讯云、百度翻译(填自己的密钥,各家都有免费额度);
  - AI 大模型:结合上下文修正识别错误,译文最通顺,可以在字幕条上直接换模型。
  - 目标语言默认「自动」(中文用户:中文 → English,其他语言 → 中文)。
- **AI 服务**(可选,任意 OpenAI 兼容接口,设置 › AI 服务):接口和 Key 配置一次,听写后润色、AI 翻译、字幕总结各自选模型。填好地址和 Key 后自动拉取模型列表供选择。
- **设置按场景组织**:听写(润色、听写翻译)、实时字幕(显示、行数、翻译、字幕记录)、翻译服务(语言包与在线服务密钥)、AI 服务(LLM 接口)。

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

- API Key(包括 AI 后处理的 Key)只保存在本机文件 `~/Library/Application Support/InputBetter/credentials.json`,权限 0600,不使用钥匙串。
- 使用云端识别时,录音会发送到对应服务商。

## 目录

| 路径 | 内容 |
| --- | --- |
| `app/` | macOS app,Swift 6 / SwiftUI,用 XcodeGen 生成工程,要求 macOS 26+ |
| `firmware/` | Passport 固件,ESP-IDF 5.5.3 / LVGL 9,见 `firmware/README.md` |
| `docs/protocol.md` | 设备通信协议 |
| `docs/device-ui.md` | 设备界面与交互设计 |
| `docs/changelogs/` | 每次修改的记录 |
| `website/` | 官网(静态页面与部署脚本),见 `docs/website.md` |

## 编译运行

已签名并经 Apple 公证的安装包可以在官网下载:<https://input.0os.io>(macOS 26+,Apple 芯片)。也可以自行编译,需要 Xcode 27 和 XcodeGen(`brew install xcodegen`)。

默认 ad-hoc 签名。想让重新编译后辅助功能权限不失效,可以新建 `app/Config/Signing.local.xcconfig`(已在 .gitignore 中)填入自己的开发证书:

```
CODE_SIGN_IDENTITY = Apple Development: Your Name (XXXXXXXXXX)
DEVELOPMENT_TEAM = YOURTEAMID
```

```bash
cd app
./scripts/build.sh            # 产物:app/build/InputBetter.app
./scripts/test.sh             # 单元测试
open build/InputBetter.app
```

第一次启动会进入引导,依次是:

1. 授予麦克风与辅助功能权限
2. 下载模型
3. 设置快捷键
4. 翻译与 AI(可选,可一键下载系统翻译语言、连接 AI)
5. 连接 Passport(可选,可一键刷固件、设置 Passport 麦克风)
6. 试一试

## 烧录 Passport 固件

app 不内置固件,刷写时从官网下载最新固件([input.0os.io/firmware/manifest.json](https://input.0os.io/firmware/manifest.json)),下载后逐个校验 SHA-256。

**在 app 里一键刷入(推荐)**:

- 位置:引导的「连接 Passport」一步,或 设置 › Passport;设置页会显示官网是否有新固件。
- `build.sh` 会用 `scripts/bundle-device-assets.sh` 把烧录工具 esptool 打包进 app。
- 第一次刷某台设备前,app 会把整片 Flash 备份到 `~/Library/Application Support/InputBetter/Backups/`。

**在官网用浏览器刷入**:用电脑上的 Chrome / Edge 打开 [input.0os.io](https://input.0os.io/#firmware),先退出 InputBetter app,点「连接并刷入」。可选先把整片 Flash 备份下载到本机。网页会检查芯片、Flash 大小和 `cardid` 分区,不是 Passport 就停止。

也可以用命令行:

```bash
./scripts/flash-firmware.sh
```

- 第一次烧录某台设备前,脚本会把整片 Flash 备份到 `~/esp/passport-backups/`。
- 烧录前请先退出 InputBetter。

三种方式都只写 bootloader、分区表和应用,不擦除整片 Flash,绝不写 `cardid` 分区。

发布新固件:编译固件后运行 `website/deploy/deploy.sh`,它会调用 `scripts/package-firmware.sh` 生成清单和镜像并发布到官网,app 和网页随即可以刷到新版本。

## Vibe Coding 通知

在 设置 › Vibe Coding 里对 Claude Code 和 Codex 分别点「一键配置」:

- Claude Code:写入 `~/.claude/settings.json` 的 hooks。
- Codex:写入 `~/.codex/hooks.json`。配置后需要在 Codex 里输入 `/hooks` 信任一次。不会改动 Codex 的 `notify` 设置。

两者都只追加 InputBetter 自己的条目,原文件会先备份为 `.inputbetter.bak`。

## 本地化

- 源语言是简体中文。
- 英文翻译在 `app/Localization/en.json`,按界面语境翻译。
- 改了界面文字后运行 `app/scripts/update-strings.sh`,重新生成 `Localizable.xcstrings`;缺少翻译时脚本会列出来。

## 参考项目

InputBetter 参考了以下开源项目的设计与做法(未复制其代码):

- [betterwispr](https://github.com/opennookorg/betterwispr):状态胶囊条、按应用采集系统声音、粘贴输入。
- [MemoEcho](https://github.com/isecret/MemoEcho):SenseVoice 接入、首次引导、剪贴板恢复。
