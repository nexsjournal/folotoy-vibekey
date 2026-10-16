# InputBetter

本地语音输入的 macOS app,配套 FoloToy AI Passport 硬件。默认所有语音识别都在本机完成,也可以接入自己的云端识别服务。

- **听写**:按住快捷键(默认 ⌥ 空格,可改)说话,松开后文字输入到当前光标处。也可以短按开始、再按一次结束。
- **实时字幕**:选一个应用(例如 Chrome 里播放的 YouTube),把它的声音实时转成字幕。底部的状态胶囊会展开成可拖动的字幕条。可选双语翻译。
  - 字幕条上的「字幕记录」可以查看本场的全部字幕,拷贝或保存成文本文件。
  - 结束字幕时会询问是否保存(可关闭)。app 不保存字幕历史,记录只在内存里。
- **Passport 硬件**(右侧从上到下:上键 / 下键 / OK 键,屏幕右边的提示贴着对应按键):
  - 按住 OK 说话;
  - 上键回车,下键 Esc;
  - 长按上键切换模式;
  - 长按下键打开「切换应用」列表,选中后把 Mac 上该应用的窗口前置并聚焦。

  Claude Code / Codex 完成或需要确认时,设备会响铃提醒。专为 vibe coding 设计。
- **界面语言**:简体中文 / English / 跟随系统(设置 › 通用),切换即时生效。
- **AI 后处理**(可选,任意 OpenAI 兼容接口):润色口语、说中文输入英文、字幕翻译。填好地址和 Key 后自动拉取模型列表供选择。

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

## 编译运行

本仓库只提供源码,暂不提供打包好的 app 下载,请自行编译。需要 Xcode 27 和 XcodeGen(`brew install xcodegen`)。

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
4. 配置 AI(可选)
5. 连接 Passport(可选,可一键刷固件、设置 Passport 麦克风)
6. 试一试

## 烧录 Passport 固件

推荐在 app 里一键刷入:

- 位置:引导的「连接 Passport」一步,或 设置 › Passport。
- `build.sh` 会用 `scripts/bundle-device-assets.sh` 把固件和 esptool 打包进 app。
- 第一次刷某台设备前,app 会把整片 Flash 备份到 `~/Library/Application Support/InputBetter/Backups/`。

也可以用命令行:

```bash
./scripts/flash-firmware.sh
```

- 第一次烧录某台设备前,脚本会把整片 Flash 备份到 `~/esp/passport-backups/`。
- 烧录前请先退出 InputBetter。

两种方式都只写 bootloader、分区表和应用,绝不写 `cardid` 分区。

## Vibe Coding 通知

在 设置 › Vibe Coding 里对 Claude Code 和 Codex 分别点「一键配置」:

- Claude Code:写入 `~/.claude/settings.json` 的 hooks。
- Codex:写入 `~/.codex/hooks.json`。配置后需要在 Codex 里输入 `/hooks` 信任一次。不会改动 Codex 的 `notify` 设置。

两者都只追加 InputBetter 自己的条目,原文件会先备份为 `.inputbetter.bak`。

## 本地化

- 源语言是简体中文。
- 英文翻译在 `app/Localization/en.json`,按界面语境翻译。
- 改了界面文字后运行 `app/scripts/update-strings.sh`,重新生成 `Localizable.xcstrings`;缺少翻译时脚本会列出来。
