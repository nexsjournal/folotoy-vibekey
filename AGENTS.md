# InputBetter

本地语音输入 macOS app(听写输入 + 应用声音实时字幕),配套 FoloToy AI Passport 硬件固件。

## 目录

| 路径 | 内容 |
| --- | --- |
| `app/` | macOS app(Swift 6 / SwiftUI + AppKit,XcodeGen 生成工程,macOS 26+);`app/Packages/AppUpdateKit` 是可复用的检查更新包 |
| `firmware/` | Passport 固件(ESP-IDF 5.5.3,ESP32-C3,LVGL 9),为本项目全新编写 |
| `docs/` | 协议、设备交互设计、修改记录 |
| `scripts/` | 烧录等脚本 |
| `website/` | 官网 input.0os.io(静态页面 + 部署脚本) |

## 常用命令

```bash
cd app && ./scripts/build.sh                 # 编译 app → app/build/InputBetter.app(会顺带打包固件与 esptool)
cd app && ./scripts/test.sh                  # 单元测试
./scripts/clean.sh                           # 删除所有编译 / 测试 / 打包产物(--keep-downloads 保留 esptool 与 ESP-IDF 组件,--dry-run 只列出)
cd app && ./scripts/update-strings.sh        # 改了界面文字后重新生成 String Catalog(英文在 app/Localization/en.json)
cd firmware && ./tools/validate.sh --host    # 固件主机测试
./scripts/flash-firmware.sh                  # 命令行烧录固件(先退出 InputBetter)
cd app && ./scripts/release.sh               # 打包签名公证的 DMG + Sparkle 签名(凭据用环境变量或本机 app/Config/Release.local.env 传入,见 docs/website.md)
cd app && ./scripts/publish-update.sh        # 部署官网后把新版本登记到更新后台,已安装的 app 会提示更新(地址密钥只在本机)
cd app && ./scripts/install.sh               # 自测:编译签名公证正式版,替换 /Applications/InputBetter.app 并启动
./scripts/package-firmware.sh                # 把 firmware/build 整理成官网固件清单与镜像(deploy.sh 会自动调用)
website/preview.py                           # 本地预览官网(自动替换占位符,http://127.0.0.1:8788/)
website/deploy/deploy.sh <user@host> <key>   # 部署官网 input.0os.io(含最新 DMG 和固件);服务器地址和密钥不写进仓库
```

调试构建支持的环境变量见 `app/InputBetter/Debug/DebugHooks.swift`:

- `IB_ONBOARDING_STEP` / `IB_SETTINGS_PANE`:直接打开某一页;
- `IB_CLOUD_CONFIG=volcengine`(`CloudProvider` 的 rawValue):配合 `IB_SETTINGS_PANE=models` 直接弹出该云端服务的配置表单;
- `IB_TRANSCRIBE_FILE`:识别音频文件并打印耗时;
- `IB_DOWNLOAD`:下载模型;
- `IB_SUBTITLE_APP`:直接开字幕(`IB_SUBTITLE_TRANSLATE=1` 同时打开翻译,`IB_TRANSLATION_METHOD=system|mt.deepl|llm` 先切换字幕的翻译方式,`IB_CAPTION_TRACE=1` 打印翻译时序,排查"译文跟不上");
- `IB_SHOW_TRANSCRIPT`:打开字幕记录窗口(`IB_TRANSCRIPT_TAB=summary` 打开「总结」页,`IB_SUMMARIZE_AFTER=秒` / `IB_SUMMARIZE_ALL_AFTER=秒` 定时触发一次分段 / 全文总结,`IB_TRANSCRIPT_TRANSLATE_AFTER=秒` 定时把字幕记录「全部重新翻译」一次并打印结果,可配合 `IB_DEMO_CAPTIONS`);
- `IB_TRANSLATE_CONFIG=deepl`(`TranslationProvider` 的 rawValue):配合 `IB_SETTINGS_PANE=translation` 直接弹出该在线翻译服务的配置表单;
- `IB_DEMO_CAPTIONS`:用示例双语字幕显示字幕条(不采集音频),加 `IB_SHOW_HEADER=1` 一直显示字幕条标题栏,加 `IB_STOP_PROMPT=1` 立即弹出「结束字幕？」气泡;
- `IB_SHOW_PILL`:显示状态条;`IB_PILL_RESULT=typed|warning`:状态条停在听写完成卡片上(warning 是很长的失败说明),检查卡片宽度;
- `IB_FIRMWARE_MANIFEST=url`:固件清单改用这个地址(默认官网);`IB_FLASH_FIRMWARE=1`:Passport 连上 USB 后自动刷一次固件;
- `IB_UPDATE_DEMO=available|required`:用假数据弹出可选 / 强制更新窗口(不联网);`IB_UPDATE_FEED=url`:检查更新改用这个接口。

## 规则

### 每次修改都要记录到 docs(必须遵守)

- 每次对代码、固件、文档、脚本做了修改,结束前都要在 `docs/changelogs/` 下**新建一个文件**记录本次修改,不要追加到已有文件,也不要写进单个汇总文件。
- 文件名为修改时间:`%Y-%m-%d-%H-%M.md`,例如 `docs/changelogs/2026-10-15-23-39.md`,用 `date '+%Y-%m-%d-%H-%M'` 获取本机当前时间,不要估算。同一分钟内已有同名文件时,把内容补进该文件。
- 文件内容格式:

  ```markdown
  # YYYY-MM-DD HH:MM — 一句话标题

  - 改了什么(涉及的模块 / 文件)
  - 为什么改
  - 验证情况(编译、测试、真机;没验证的写明)
  ```

- **每完成一个任务,相关文档都要同步更新**(不只是 changelog):
  - 功能或调用链变化 → `docs/architecture.md`;
  - 协议或设备交互变化 → `docs/protocol.md` / `docs/device-ui.md`;
  - 用法、命令、功能列表变化 → `README.md`、`firmware/README.md`、本文件的「常用命令」;
  - 完成后在回复里说明更新了哪些文档。

### 代码要求(必须遵守)

- **模块化**:按职责拆分目录与文件(音频、识别、模型、听写、LLM、快捷键、界面、设备……),一个文件只做一件事。
- **解耦合**:模块之间通过协议和小接口通信(如 `AudioSource`、`ASREngine`、`ASRSession`、`DeviceLink`),不直接依赖彼此的内部实现;界面只读状态、发意图,不写业务逻辑;避免全局单例,依赖由 `AppState` 注入。
- **调用链清晰**:每个功能都要能写出一条清晰的逻辑调用链(如 `A → B → C`),记录在 `docs/architecture.md`;改动功能时同步更新对应调用链。
- **不重复实现**:同一能力只实现一次(如重采样、模拟按键、电平计算),其他地方调用它;发现重复要合并。
- **测试与排查沿调用链进行**:写测试、找 BUG 时,从功能的调用链出发,逐个验证链上每个函数的输入输出是否正确,先定位是哪一环出错再修。
- **符合业内通用做法**:每个功能都按成熟产品 / 平台推荐的方式实现(例如 macOS 权限、窗口、快捷键、本地化、硬件烧录、音频采集的标准做法),不能为了尽快完成或省事而省略必要环节(错误处理、边界情况、取消、恢复、权限提示、可访问性等)。不确定业内做法时先查官方文档或成熟开源实现,再动手。
- **注释清晰**:每个类型、关键函数和不直观的实现都写中文注释,说明它做什么、为什么这样做,以及线程、生命周期等约束;不写复述代码的废话注释。

### 界面文字

- 源语言简体中文;每条界面文字都要有准确、符合语境的英文翻译(`app/Localization/en.json`),改完运行 `update-strings.sh` 确认没有缺失。
- 视图里的字面量会自动本地化;来自模型 / 枚举 / 错误的文字用 `String(localized:)`;组件的文字参数用 `LocalizedStringKey`。
- 不要用文案做逻辑判断(用类型化枚举,如 `DictationResult`、`DictationFailure`)。

### 敏感信息(必须遵守)

GitHub 仓库是公开的,提交前确认不含敏感信息:

- 不提交:服务器地址、SSH 密钥、Developer ID 证书、公证用的 App Store Connect 密钥(Key ID、Issuer ID、`.p8`)、各类 API Key、`Signing.local.xcconfig`。这些只在本机,运行脚本时用参数或环境变量传入,文档里只写占位符。
- 不提交:DMG、Passport 整片 Flash 备份(含设备身份凭证)、设备 MAC 等真实设备标识(测试里用虚构值)、个人邮箱、本机绝对路径。
- 提交前用 `git diff --cached` 检查;`.gitignore` 已屏蔽常见的密钥、安装包和备份文件。

### 其他

- passport-keys(FoloToy AI Passport 的另一个开源项目)只是参考实现,本项目不依赖它,也不复制其中的业务逻辑。
- 烧录固件前必须先确认已有整片 Flash 备份(`~/esp/passport-backups/`),绝不写 `cardid` 分区(`0x356000`)。
