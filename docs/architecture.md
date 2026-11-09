# VibeKey 架构与功能调用链

本文按功能列出调用链。改动功能时,同步更新对应的链。测试和排查问题时,也从链出发,逐个验证每一环的输入和输出。

## Wi-Fi 与远离电脑的输入（本地分支）

- 配网：`PassportWiFiSection → DeviceLink.configureWiFi → WiFiProvisioning.encoded → USB → ib_wifi_handle_usb_line → NVS → config_task → Wi-Fi STA / mDNS`。设备最多保存 4 组网络，每组独立 `SSID + password + host + PSK`；密码仅在表单内存和 USB 配网命令中使用，Mac 只持久保存 SSID、随机主机名与 PSK。`ib_wifi_store` 是纯 C 数据模型，负责增删、active 切换与旧单网络结构迁移。
- Wi-Fi 录音：`ib_audio → ib_app.audio_tx → ib_wifi_send_audio → TLS → DeviceLink.receiveWiFi → MicStream`。录音和控制分别入队，TLS 任务轮询收发并保留未写完的帧。应用任务只在 Wi-Fi 麦克风打开时关闭无线省电；断线时记录 STA 原因或 TLS 错误，重新关联后建立新会话。
- 无线连接：`WiFiClient(Network TLS-PSK) → DeviceLink.beginHandshake → ib_wifi(server_task/esp_tls) → ib_app`。Mac 同时尝试所有本机已保存的 `host.local`，第一个完成 TLS 握手的就是设备当前网络，因此设备端换网后无需 USB 先通知 Mac。TLS 任务独占 socket，音频任务经有界队列发送；同一份协议解析器与 MicStream 解码器服务 USB/Wi-Fi。
- 无线模式互斥：NVS `ib_wifi/networks` 非空时，本轮启动不初始化 BLE，使用官方 `esp_bt_mem_release` 释放蓝牙内存；无网络时保持 BLE。新增、选择或移除网络后重启到新的 host / PSK；USB 清除全部配网后重启恢复 BLE。USB 始终可用；Wi-Fi 失联时通过 USB 或设备离线网络列表修复，不承诺同次启动自动降级 BLE。
- C3 内存预算：Wi-Fi 静态 RX 4、动态 RX/TX 各 8；NimBLE MSYS 各 6；TLS 动态缓冲、输出 1024 字节；Wi-Fi 发送队列每项 512 字节。真机首次暴露默认 Wi-Fi 缓冲初始化不足，不能用“编译通过”替代入网测试。
- 拔线：`DeviceLink.linkLost → 选择 USB > Wi-Fi > BLE → resendCachedState → setActive → MicStream.setActive`。Wi-Fi 在 USB 期间保持待机，重连沿用已有配对资料。
- 独立输入：`设备 OK down → DeviceBridge → DictationController.pressDown → 立即启动 PassportMicSource + 并行 DeviceInputTarget.prepare（最多 5 s；通用 AX 遍历失败时用 Codex 适配器复核）→ AppSwitcher.activate/focusTextInput → ASR → 后处理 → 等待目标准备完成 → TextInserter`。目标失败或取消会关闭音源，迟到结果不能插入。
- 应用选择：`设备应用列表确认 → AppSettings.deviceTargetBundleID/deviceTargetName`，下次录音或上/下键先恢复该目标；默认 Codex。Codex 发送/停止沿用校验后的专用适配器；用户明确选择的其他应用使用 Enter/Esc 映射。
- Mac 录音胶囊：starting 使用 warning，recording 使用 success，danger 留给失败，不再用红点表达正常采音。
- 设备字幕：`SubtitleController.feed.captions → DeviceBridge.sync（16 Hz）→ DeviceLink.sendCaption（live 最多 10 Hz，定稿立即）→ caption（UTF-8）→ ib_app → ib_ui_set_caption → SUB 页`。应用名、原文、译文分别显示；断线重连后随 state 一起补发。
- 连接保活：VibeKey 是菜单栏 App，空闲会被 App Nap 降频，DeviceLink 的 5 秒心跳可能停超过固件 15 秒超时；`AppState.launch` 持有 `userInitiatedAllowingIdleSystemSleep` activity 保持心跳，允许系统正常休眠。设备 OFFLINE 页按 OK 发送 `wake`，Mac 重置该链路握手并重发 `hello`，不依赖拔插线或 Codex 消息 hook 唤醒。

## 模块与依赖方向

```
App(AppState 组合根)
 ├─ Hotkey ─┐
 ├─ Pill ───┤ 只读状态、发意图
 ├─ Settings / Onboarding / UI
 ├─ Dictation ──→ Audio ──→ ASR ──→ LLM / Translate ──→ Support/KeySender
 ├─ Subtitles ──→ Audio(AppAudioTap)──→ ASR ──→ Translate(系统翻译 / 在线机器翻译 / LLM,一次一种)
 ├─ Bridge(DeviceBridge / DeviceStateMapper)──→ Device(DeviceLink)
 ├─ Vibe(KeyAction / AgentNotifier / AgentHookInstaller)
 ├─ Models(ModelManager / ModelCatalog)
 ├─ Translate(TranslationService / SystemTranslator / LanguageDetector / MachineTranslation / Batch)
 │     ──→ Translation 框架 + 在线翻译服务(Support/Signing、Support/CredentialStore)+ LLM
 ├─ ASR/Cloud(CloudASRStore / CloudASREngine / StreamingCloudSession + RealtimeCodec)──→ Support/CredentialStore
 └─ Update(UpdateFeeds / UpdatePromptView)──→ Packages/AppUpdateKit(本地 Swift 包,与 app 无关,可复用)
```

依赖规则:

- 下层不依赖上层。
- 跨模块只通过协议或小接口:`AudioSource`、`ASREngine`、`ASRSession`、`SegmentDecoder`、`MachineTranslator`、`DeviceLink` 公开方法、`PillActions`、`HotkeyManager.Actions`、`DeviceBridge.Hooks`、`UpdateFeed`(AppUpdateKit)。

## 只有一份实现的公共能力

| 能力 | 唯一实现 | 使用者 |
| --- | --- | --- |
| 音频格式转换(重采样 / 混音) | `AudioConverter`(Audio/AudioSource.swift) | MicSource、AppAudioTap、AppleSpeechSession、DebugHooks |
| 采样 → PCM 缓冲 | `AudioFormats.buffer(from:)` | AppleSpeechSession |
| 电平计算 / 平滑 | `AudioFormats.level(of:)`、`AudioFormats.smoothLevel` | DictationController、SubtitleController、PassportSetupModel |
| 模拟按键 / 组合键 / 短文本 | `KeySender`(Support/KeySender.swift) | TextInserter(⌘V)、DeviceBridge(Passport 按键动作) |
| 键盘布局键码 | `KeyLayout.keyCode(for:)` | TextInserter、KeySender |
| 识别文本处理 | `TranscriptText`(join / normalize / toSimplified / isHallucination) | SegmentedSession、AppleSpeechSession、DictationController、SubtitleController |
| 非流式模型分段识别 | `SegmentedSession` + `VoiceActivityDetector` | SenseVoiceEngine、WhisperEngine |
| LLM 请求(一次 / 流式) | `LLMClient.complete` / `LLMClient.stream` | TextProcessor(润色、翻译、批量、润色译文)、TranscriptSummarizer、LLMConfigForm(测试连接) |
| 识别后词汇纠错(正式写法 / 别名) | `VocabularyCorrector` | DictationPostProcessor、AppSettings.vocabularyTerms |
| 设备 ASCII 文本 | `DeviceText.ascii` | DeviceLink 发出的所有命令 |
| 设备状态映射 | `DeviceStateMapper` | DeviceBridge |
| esptool 调用与输出解析 | `EsptoolRunner` | FirmwareFlasher |
| 固件清单校验(地址 / 路径 / 校验值) | `FirmwareManifest.parts`(网页端 `flasher.js` 的 `partsOf` 同规则) | FirmwareDownloader |
| Agent hook 合并写入 | `AgentHookInstaller.install` | VibePane(Claude Code、Codex) |
| 快捷键卡片 | `ShortcutsCard` | 引导快捷键页、设置 › 快捷键 |
| 界面语言选择 | `LanguagePicker` / `LanguageState` / `L10n` | 设置 › 通用、欢迎页,所有根视图 |
| 设备按键提示(图标) | `DeviceStateMapper.keyHints` → `DeviceIcon`、`KeyAction.deviceIcon`、`DeviceIcon.sfSymbol` | DeviceBridge、Passport 示意图 |
| 按键手势识别 | `KeyPressTracker` | DeviceBridge |
| 应用前置聚焦 | `AppSwitcher.activate` | DeviceBridge(切换应用) |
| Agent 项目 / 会话读取与切换 | `AgentSessionCatalogLoader` → `AgentSessionRegistry`(Codex / DSH 专用 + 通用 AX 解析) | DeviceBridge(长按下键) |
| 密钥存储(本机 0600 文件,不用钥匙串) | `CredentialStore` | AppSettings.llmAPIKey、CloudASRStore、MachineTranslationStore |
| 云端流式会话(连接 / 缓冲 / 超时 / 重连) | `StreamingCloudSession` | 火山引擎、百炼、ElevenLabs、Soniox(各自只实现 `RealtimeCodec`) |
| Float → PCM16 / WAV | `AudioFormats.pcm16` / `AudioFormats.wav` | StreamingCloudSession、OpenAITranscriptionDecoder |
| gzip | `Gzip` | VolcengineCodec |
| 云端服务创建会话 / 测试连接 | `CloudASREngine.session` / `CloudASREngine.test` | CloudASREngine.makeSession、CloudConfigSheet |
| OpenAI 兼容接口地址 / 鉴权 / 错误信息 / 模型列表 | `OpenAICompatibleAPI` | LLMClient、OpenAITranscriptionDecoder、LLMConfigForm、CloudASREngine.fetchModels |
| 模型下拉选择(列表 + 手动输入 + 重新获取) | `ModelPickerField` | LLMConfigForm、CloudConfigSheet |
| 翻译入口(按翻译方式分派,一次一种) | `TranslationService`(translateLine / translateBatch / translateChunk / draft / refine / translateDictation) | SentenceTranslator、LiveDraft、SubtitleController、TranscriptTranslator、DictationController |
| 翻译方式(系统 / 在线服务 / AI + 模型) | `TranslationMethod`(字幕 `AppSettings.subtitleTranslationMethod`、听写 `dictationTranslationMethod`) | 字幕条方式菜单、设置 › 翻译、字幕记录、听写 |
| 在线机器翻译(6 家) | `MachineTranslator` 协议 + `Providers/*Translator`(makeRequest / parse)、`MachineTranslatorFactory` | TranslationService、TranslationProviderSheet(测试连接) |
| 在线翻译凭据 | `MachineTranslationStore` | TranslationService、设置 › 翻译 |
| 请求签名(HMAC-SHA256 / MD5) | `SigningCrypto`、`VolcengineSigner`、`TencentTC3Signer` | 火山、腾讯、百度翻译 |
| 分块(按语言对分组、跳过同语言、按上限切块) | `BatchPlanner` + `BatchLimits` | TranslationService.translateBatch / plan |
| 限流(并发 + QPS,字幕和记录共用) | `RequestGate` | TranslationService |
| 整句译文去重 / 合并请求 | `SentenceTranslator` | CaptionFeed(字幕条)、SubtitleController(记录) |
| 边说边译(片段翻译 + 尾巴重翻 + 稳定) | `LiveDraft` + `DraftSegments` + `LiveDraftPolicy` + `DraftStabilizer` | CaptionFeed |
| 翻译方式 / 目标语言菜单项 | `TranslationMethodMenuItems`、`TargetLanguageMenuItems` | 字幕条标签、字幕记录工具条 |
| LLM 模型列表(缓存) | `LLMModelCatalog` | 翻译方式菜单、总结页 |
| 流式识别结果稳定化(LocalAgreement) | `CaptionSegmenter` | CaptionFeed |
| 断句 | `SentenceSplitter` | SubtitleController(记录按句)、CaptionSegmenter |
| 字幕条两行滚动文字 | `RollingCaptions` | CaptionFeed |
| LLM 配置表单(预设 / 地址 / Key / 模型拉取 / 测试) | `LLMConfigForm`(绑定三项配置) | 设置 › AI、引导 |
| 字幕记录分段总结 | `TranscriptSummarizer` | SummaryView |
| 系统离线翻译 | `SystemTranslator`(Translation 框架,会话缓存) | TranslationService |
| 语言识别 / 同语言判断 | `LanguageDetector` | TranslationService、TargetLanguage.resolved |
| 系统翻译语言包状态与下载(按目标语言) | `SystemTranslationRow`(`.translationTask` → prepareTranslation) | 设置 › 翻译 › 系统翻译「配置」(SystemTranslationSheet)、引导「翻译与 AI」 |
| 字幕翻译时序追踪(调试) | `CaptionTrace`(IB_CAPTION_TRACE=1) | CaptionFeed、LiveDraft |
| 结束字幕(含「结束字幕？」气泡确认) | `AppState.stopCaptions` | 字幕条 ⏹、⌃ 菜单 / 菜单栏、快捷键、设置 › 实时字幕、Passport、切换应用 |
| 字幕记录保存成文件 | `TranscriptSaver`(`CaptionTranscript.plainText`) | AppState.stopCaptions / prepareToQuit、字幕记录窗口 |

## 1. 听写(快捷键按住说话)

```
KeyboardShortcuts.onKeyDown(.dictate,默认 ⌥空格)
 → HotkeyManager.Actions.dictateDown
 → DictationController.pressDown(mode:)
 → PressInterpreter.down → .start
 → DictationController.start(mode:)(正在忙时先 PressInterpreter.reset 再忽略,下一次按键不会被吞掉)
     ├─ DictationEngineSource.dictationEngine(默认 InstalledDictationEngines → ModelManager.isInstalled / EngineRegistry.engine(for:))
     ├─ makeSource() → MicSource | PassportMicSource ── AudioSource.start
     │     MicSource: AVAudioEngine tap → AudioConverter.convert → onSamples
     │     onSamples → SampleBuffer.append(会话就绪前先缓存)
     │                → AudioFormats.level → DictationController.updateLevel → AudioFormats.smoothLevel
     └─ sessionTask: ASREngine.makeSession(ASROptions(.dictation))
           → SampleBuffer.attach(session) → ASRSession.feed
           → session.events → DictationController.handle(.partial/.final) → liveText → PillView 气泡

松开:
KeyboardShortcuts.onKeyUp(.dictate) → HotkeyManager.Actions.dictateUp
 → DictationController.pressUp → PressInterpreter.up → .stop
 → DictationController.stop
     → (150 ms 尾音)AudioSource.stop
     → await sessionTask → ASRSession.finish → 文本(等事件任务处理完,结束时才报的错误也能显示)
     → TranscriptText.normalize
     → VocabularyCorrector.apply(词汇表：正式写法 + 常见误识别别名；毫秒级、不调用模型)
     → DictationPostProcessing.process(默认 DictationPostProcessor):TextProcessor.polish | TranslationService.translateDictation
         (按 AppSettings.dictationTranslationMethod:AI → TextProcessor.translate;系统 / 在线服务 → translateBatch;目标 = translateTarget)
         失败退回原文,但带上 PostProcessWarning(.untranslated / .unpolished + 原因),结果不再显示成绿色「已输入」
         可用性:TranslationService.canTranslateDictation(按听写的方式和目标语言,系统翻译看听写语言对的语言包),
           不可用 → fail(.translationUnavailable(reason:)),原因来自 unavailableReason
     → TextInserting.insert(默认 TextInserter)
          → snapshot 剪贴板 → copy → KeySender.press(⌘V, KeyLayout) → 立即返回 .pasted;
            恢复剪贴板放独立 Task(700 ms 后,仍校验 changeCount;PendingRestore 把连续多次输入串起来、沿用第一份快照)
     flowTask 每个 await 之后检查 Task.isCancelled:处理中取消(Passport 长按下键、退出)不再粘贴、不报「引擎未就绪」
     → succeed(DictationResult) / fail(DictationFailure)(类型化结果,界面用 .title 显示)→ 成功 1.2 s / 失败 2 s / 带原因的警告(翻译失败已输入原文、翻译不可用)4 s 后回到 idle
       警告和「翻译不可用」的胶囊可点击 → PillActions.openDictationSettings → 设置 › 听写
```

识别会话内部分两种。

非流式模型(SenseVoice / Whisper):

```
SegmentedSession.feed → input stream → SegmentedSession.run
 → VoiceActivityDetector.accept / popSegments
 → commit(逐句解码,SenseVoice)| 只记录语音区间(Whisper 整段模式)
 → 定期 partial:SegmentDecoder.decode(未定稿或整段音频)
 → finish:VoiceActivityDetector.flush → 预览已覆盖全部语音则直接返回,否则整段 decode,再不行就 TranscriptText.join(逐句结果)
```

`WhisperDecoder.decode` 内部:

```
WhisperRunner.detectLanguage(自动模式,3 秒内复用缓存)
 → WhisperRunner.promptTokens(中文提示词 + 词汇表)
 → WhisperRunner.transcribe
 → TranscriptText.toSimplified
```

流式模型(Apple Speech):

```
AppleSpeechSession.feed
 → AudioFormats.buffer → AudioConverter.convertBuffer(转成分析器格式)
 → AnalyzerInput → SpeechAnalyzer
 → transcriber.results → .partial / .final
finish → finalizeAndFinishThroughEndOfInput → TranscriptText.join
```

云端模型(听写和字幕都可用,见「8a. 云端识别」):

```
EngineRegistry.engine(for: "cloud-…") → CloudASREngine.makeSession → CloudASREngine.session(provider:config:options:)
 ├─ 流式(火山引擎 / 百炼 / ElevenLabs / Soniox):StreamingCloudSession(makeCodec)
 │    feed → inbox → run → AudioFormats.pcm16 → RealtimeCodec.audioMessage → CloudConnection.send
 │    CloudConnection.receive → RealtimeCodec.parse → .ready / .partial / .final / .completed / .failure
 │    finish → 补发尾包 + RealtimeCodec.finishMessages → 等 .completed(或结束后的定稿)→ 拼接定稿
 │    Soniox(SonioxCodec):Bearer 头鉴权 → 配置消息(pcm_s16le 16 kHz;字幕开端点检测,听写不开;language_hints、context.terms)
 │      → 二进制 PCM → tokens(最终 token 累加、非最终 token 整体替换;第一条响应即 .ready)
 │      → <end> / <fin> 切出一句 .final → 结束:空文本帧 → finished:true → .completed;error_code → .failure
 └─ OpenAI 兼容:SegmentedSession(OpenAITranscriptionDecoder)
      → VAD 分段 → 松开后整段 AudioFormats.wav → MultipartForm → POST /audio/transcriptions
出错:会话发出 TranscriptEvent.failure → DictationController.streamError(没有文字时 fail(.other))
 / SubtitleController.streamError(字幕条红字);字幕模式断线后指数退避自动重连,断线时的中间结果先定稿
会话层(CloudStreamPump,参数 CloudStreamTiming):就绪超时(8 秒)不再静默——报告 CloudASRError.timeout(服务名),
 「测试连接」因此能发现地址 / 资源 ID 错误;握手 401 / 402 / 403 → CloudASRError.rejected(status:)(isFatal,不重连);
 字幕模式连续 3 次(maxFailedAttempts)没能就绪就报告最近一次错误、停止重连,就绪过一次计数和退避复位;
 每条连接(CloudConnection)结束时 finishTasksAndInvalidate,重连前先关旧连接,迟到的消息按代号忽略
```

## 2. 听写(Passport OK 键)

```
DeviceLink(USB/Wi-Fi/BLE)→ DeviceMessage.parse → RecentEventFilter → DeviceLink.lastKey / onKey
 → DeviceBridge.handle(.ok, .down)
 → DictationController.pressDown(mode: 设备模式 dict/tr)        // 之后与第 1 节相同
音源为 Passport 时:PassportMicSource.start → DeviceLink.setMic(true)
 → 设备 ADPCM 帧 → StreamDecoder → MicStream → IMAADPCMDecoder → onMicSamples → SampleBuffer
```

## 3. Passport 状态同步

```
DeviceBridge.sync(16 Hz 定时器,或连接变化时)
 → DeviceStateMapper.state(phase, mode, 字幕状态)  → DeviceLink.sendState(变化时)
 → DeviceStateMapper.keyHints(...)               → DeviceLink.sendKeyHints(内部去重)
 → DeviceLink.sendLevel(录音 / 字幕时,内部限流 50 ms)
 → DeviceLink.sendConfig(变化时;5 分钟校时)
所有命令:HostCommand.encode → DeviceText.ascii → USB SerialPort.write | WiFiClient.send | BLEClient.send

Mac 握手:DeviceLink.beginHandshake → hello → handleHello
 → noteDeviceBoot(boot 与上次握手不同 → notice 日志「device rebooted」)
 → 重发 config / state / keys / mic → setActive
```

固件侧(`firmware/main/ib_app.c`,ib_app 任务每 100 ms 一轮):

```
链路:app_task → refresh_links
 → ib_links_usb_present(ib_usb_host_present() 原始 SOF 判断, now)   USB 在位去抖:连续 1 s 不在位才算拔线
 → ib_links_drop(USB)(确认拔线时)→ ib_links_any
 → 在线→离线:go_offline(OFFLINE 页、停麦、清 Agent;保留 s_st / s_msg,done/err 收拢到常驻页),不 wake
   OFFLINE 页由 ib_ui_offline 叠加 Flash 中的 RGB565 像素背景和现有实时点阵时钟，主机预览与固件共用背景数据
 → 离线→在线:show_screen(screen_for(s_st)) 回到离线前页面 + wake
命令:handle_command → ib_links_seen → refresh_links → state: apply_state(+ wake) | config: 只更新设置,不 wake
背光:app_task → refresh_backlight(在线且 rec/proc/sub 常亮;否则 now - s_last_activity_ms ≥ screen_off 熄屏)
 wake 来源:handle_key(按下)、apply_state、agent_show / input 重复提醒、refresh_links(离线→在线)
电量:app_task → refresh_battery(每 60 s,或 USB 在位变化时)
 → bsp_battery_soc / bsp_battery_mv → ib_charge_update(充电推断 + 已充满判定;读数 -1 不改判定,已充满只由电压 / SOC 退出)
 → ib_ui_set_battery + bat 消息(ib_format_battery)
```

设置 › Passport › 连接状态直接读 `DeviceLink.connection` / `lastMessageDate` / `firmwareVersion` /
`batteryPercent` / `batteryMillivolts`：链路与「最后在线」同屏显示，USB 发现但未握手时提供
`resumeUSB()`；不再靠设备上的 `WAITING FOR MAC` 猜是没插线还是 Mac app 没运行。

## 3a. Passport 模式与 OK 键

```
设备模式(长按上键循环 dict → tr → sub,听写进行中不切换)
 dict / tr:OK = 按住说话(短于 250 ms 取消),字幕在运行也不影响(此时设备显示字幕页,按键仍是听写模式的含义)
 sub:OK = 没有字幕时打开设备列表「CAPTIONS」选择应用 → Hooks.startCaptions;有字幕时 Hooks.stopCaptions(= AppState.stopCaptions)
       (Mac 上正显示模态框时不响应)
       上 / 下短按 = 本场字幕的翻译开关(SubtitleController.toggleTranslation,当前翻译方式可用时)/ 收起展开字幕条(仅字幕运行时)
DeviceStateMapper.state:设备临时错误(如 NO APPS,2 秒)→ 听写阶段 → 列表 → 字幕页(字幕在运行,不论模式;mode 如实上报)→ 空闲页
DeviceStateMapper.keyHints:字幕页按模式给提示(sub:停止 / 翻译(翻译不可用时隐藏)/ 收起;dict / tr:麦克风 + vibe 动作)
OK 键:听写进行中(含从 Mac 开始的)始终交给听写(pressDown / pressUp,记录 okDrivesDictation);
 连接变化时取消当前设备按住的听写;Passport 麦克风录音中断开 → DictationController.cancel
Agent 提醒:Mac 胶囊点击或设备短按 OK → DeviceBridge.openNotice;带会话 ID 的完成卡打开原聊天,其他提醒关闭。重连后重发当前未处理的提醒
固件:done / err 自动返回时回到「常驻页」(最近一次 idle / sub 的页面、模式和 msg);rec → proc 继续推流最多 500 ms 等 mic off(录完尾音)
列表页 ListSession:切换应用(长按下键)/ 选择字幕应用(sub 模式 OK),按键规则相同
列表打开时 Mac 上开始了听写:DeviceBridge.sync 关闭列表(设备已切到录音页,按键不再归列表)
定时器加在 RunLoop common 模式,菜单 / 模态框显示时设备状态照常同步
```

## 3b. Passport 按键手势(所有按键动作的入口)

```
DeviceLink.onKey(key, down|long|up, ack) → DeviceBridge.handle
 → KeyPressTracker(纯值类型,通行的按键手势规则)
     began:按下时决定这次按压的归属(normal / switcher / agentAck);防抖锁定期内整次忽略
     longPressed:标记已触发长按
     ended:返回归属 + 是否短按(松开前没触发长按)
 → 普通模式:pressBegan(OK 立即开始听写)/ longPressed(上:切换模式;下:取消录音或长按动作)
             / pressEnded(OK 结束;上下键仅在短按时执行短按动作)
 → 列表模式:switcherPressBegan(上:移动;OK:执行当前项)/ 长按下:会话页返回项目页,其余关闭 / 下键短按松开:移动
 → 列表关闭后 OK 锁定 250 ms(防抖,避免误触听写)
固件侧:ADC 按键 20 ms 去抖 + 同键松开后 60 ms 内的再次按下忽略(ib_keys)
```

## 4. Passport 按键 → vibe coding 动作

```
DeviceBridge(见 3b 的手势结果)
 ├─ agentAck 归属 → 只在同一张完成卡的 OK 短按松开时打开原聊天,其余按压关闭通知
 ├─ 字幕模式:SubtitleController.toggleTranslation | Hooks.toggleSubtitleBar → PillUIState.subtitleCollapsed
 └─ perform(KeyAction)
       → .pasteLast → DictationController.reinsertLast → TextInserter.insert
       → .nextMode  → DeviceBridge.cycleMode → sync
       → 其他       → KeySender.perform → KeySender.press / type
                      (.backspace → kVK_Delete,.forwardDelete → kVK_ForwardDelete,与键盘布局无关)
提示图标:KeyAction.deviceIcon → DeviceIcon(.bksp / .del …)→ keys 命令 → 固件 ib_icon_from_id → ib_icon_list.h
 (app 与固件的 id 集合由 ChainTests.testIconIDsMatchFirmwareTable 保证一致)
```

## 4b. Passport 切换应用 / 项目 / 会话(vibe coding)

```
长按 ▼(默认动作 KeyAction.appSwitcher,可在设置里改)
 → DeviceBridge.openContextSwitcher
     ├─ 当前 / 记住的应用 → AgentSessionCatalogLoader.load(不按 Bundle ID 白名单)
     │    → activate + ElectronAccessibility.enable(AXManualAccessibility)
     │    → AgentSessionRegistry:已知 App 用专用适配器,其余用 GenericAgentSessionAdapter
     │    → AX 快照(角色 / 标题 / 位置 / 可点状态)→ AgentNavigationParser
     │    → 有项目 / 会话 → AgentSessionCatalog → ListSession(.pickProject)
     │         choices = SWITCH APP + RECENT + 项目
     │    → 没有聊天输入框或侧栏 → 回退 openAppSwitcher
     └─ 普通应用列表:AppSwitcher.list(按窗口前后顺序 = 最近使用;默认选中当前目标)
 → OK 项目 → AgentSessionCatalogLoader.sessions(按需展开侧栏)→ ListSession(.pickSession)
 → OK 会话 → AgentSessionCatalogLoader.open
     → AXPress 会话行 → Codex/DSH 等窗口标题切换,其余等 400 ms → AppSwitcher.focusTextInput
     → 更新 settings.deviceTargetBundleID/Name → READY TO TALK
列表打开时按键:DeviceBridge.listPressBegan / listLongPressed
 ▲ / ▼ → 移动选中并重发 list;OK → 当前项;长按 ▼ → 会话页返回项目页,项目页关闭;15 秒无操作 → 关闭
AppSwitcher.activate(行为同 ⌘Tab / 点 Dock):取消隐藏 → AX 设为最前(失败退回 activate)
 → 抬起可见窗口 / 恢复最小化窗口 / 没有窗口时发送重新打开事件
通用解析(AXNavigationParser)的判定顺序:
 1. 必须有聊天输入框(AXTextArea;或占位文字像聊天框的 AXTextField),排除搜索框;
 2. 侧栏范围:AXLandmarkNavigation/Complementary、Sidebar/侧边栏/会话;没有 landmark 时要求行在输入框左侧;
 3. 项目头:项目名按钮、`Toggle sessions for`、或只有一个文字的分组头;列表内的行不算项目头;
 4. 会话行:可点击、位于 AXList/AXOutline 内或带相对时间、排除搜索/设置/发送/归档等噪声;
 5. 当前项:AXSelected / AXARIACurrent / 窗口标题 / 主内容区 AXHeading 匹配。
折叠项目在选中时按标题按钮或 `Toggle sessions for` 展开后重读。
隐私:AgentSessionCatalogLoader 只读取 AX 角色、侧栏标题、窗口标题；不读取聊天正文，名称不写日志。
健康检查:设置 › Passport › Agent 导航逐项调用 AgentSessionCatalogLoader.load，区分未安装 / 未运行 /
AX 权限缺失 / 读到项目会话 / 没有聊天输入框 + 侧栏；检测会前置目标 App，失败不改变设备目标。
列表显示:项目 / 会话名以 UTF-8(每项 ≤47 字节)下发，固件用 ib_cjk_font_12 显示中文；超出 180 px
行宽时末尾加 `..`。Agent 全屏通知的项目名先试 20 px，再降到 14 px，仍放不下才两行 + `..`。
```

## 4c. 智能体页的 Codex 用量

```
设置 › 智能体 → AgentUsageDashboard(每 60 秒 / 点刷新)
 → CodexUsageService.load
     → 找到 codex 可执行文件(~/.local/bin、Homebrew、ChatGPT.app 资源、PATH)
     → codex app-server --stdio
         initialize → account/usage/read → account/rateLimits/read
     → CodexUsageParser
         ├─ lifetimeTokens、dailyUsageBuckets → 今日 / 本周 / 累计
         ├─ secondary.usedPercent / resetsAt → 每周额度剩余、重置时间
         ├─ planType / rateLimitResetCredits → 套餐、重置券
         └─ 今日桶缺失时只读当天的 *session*.jsonl 中 token_count 行补齐
 → CodexUsageSnapshot → AgentUsageDashboard(今日 / 本周 / 累计切换)
```

隐私:只解析 token_count / rate_limits 元数据，不读取或持久化聊天正文；名称和用量不写日志。
失败处理:未安装 / 未登录 / 超时 / 进程退出都显示明确状态，不用 0 或示例数据冒充真实额度。

设备端同一条数据链:

```
切换应用 → DeviceBridge.beginUsageHome(app)
 → AgentUsageService.load(for:)
     ├─ Codex → CodexUsageService → CodexUsageSnapshot
     └─ DSH NEXT → DSHUsageReader(只读 session_projcache 开头的 tokenUsage.val.totals)
 → Codex 的 primary / secondary 分别映射为 5 小时 / 每周额度
 → DeviceUsage(格式化后的 ASCII) → DeviceLink.sendUsage → 固件 ib_ui_usage
 → 短按 OK: 隐藏用量页 → state idle(READY)，READY 底部提示 TAP OK: USAGE
 → READY 短按 OK(<500 ms): 重新显示 usageHome，不录入这次按压
 → 长按 OK: 隐藏用量页 → 正常录音链路
 → 短按 ▲/▼: 切换 utab → 重发 usage
```

DSH 的 `tokenUsage` 只累计会话总量；今日 / 本周按会话缓存文件修改时间归档，属于设备侧的近似值；
没有任何额度接口时明确显示 `NO DATA`。

## 5. 实时字幕

```
用户:胶囊 ◉ / 菜单选应用 / 快捷键 ⌥⇧S / Passport(sub 模式 OK)
 → AppState.startCaptions(app)(所有入口都先让用户选应用,不沿用上一次)
 → SubtitleController.start(app:)
     → EngineRegistry.engine(for: effectiveSubtitleModelID) → makeSession(ASROptions(.subtitles))
     → AppAudioTap.start
          → AudioProcesses.entries(for: bundleID)(bundle 前缀 + Responsibility.responsiblePID)
          → CATapDescription → AudioHardwareCreateProcessTap → 私有聚合设备 → IOProc
          → AudioConverter.convert → onSamples → ASRSession.feed + AudioFormats.level → updateLevel
          → 进程列表变化 → rebuild(force:false)
     → session.events → SubtitleController.handle
          → TranscriptText.normalize
          → .partial → SubtitleController.live = Live(startedAt: 这段第一次出现文字的时刻(沿用),text)(空文字 → nil,这段结束)
          → .partial → CaptionFeed.partial(每段话开始时锁定路径,说完这段才换,避免中途换方式导致句子重复)
              分句路径(不翻译 / 系统翻译 / 在线服务):
              → CaptionSegmenter.hypothesis(LocalAgreement-2:连续两次结果一致的词才确认,已确认文字只追加不改写)
              → SentenceSplitter.split(已确认文字,对增长稳定)→ 新确认的整句 → CaptionUnit
                  (LiveDraft.drafts(for:) 把这句对应片段的译文交给它先显示;对不上片段时整份暂定译文作为 heldDraft 先顶着,
                   等到没有句子在等译文(RollingCaptions.unitsWaiting 为 false)时 CaptionFeed.advance 丢掉 heldDraft)
              → AI 方式下分句路径不自己请求(CaptionFeed.add 跳过 LLM),定稿时 CaptionFeed.link 按文字把句子和记录关联,
                 AI 译文由 SubtitleController 串行翻译记录后同步过来——同一句只请求一次
              → SentenceTranslator.translate(同一句去重、60 毫秒内到达的多句合成一批)→ TranslationService.translateBatch → unit.translation
              → 正在说的部分 → LiveDraft.update(已确认未成句文字, 全部正在说的文字)(边说边译,设置可关):
                  DraftSegments.split(在逗号 / 句号处切,没有标点时满 14 个词硬切;已确认文字只增,切出的片段不再变)
                  → 每段 SentenceTranslator.translate 一次(译文稳定,之后成句时同样的文字直接复用)
                  → 不足一段的尾巴:LiveDraftPolicy 节流(系统 0.3 秒 / 在线服务 1 秒且多出 3 个词)→ TranslationService.draft
                     → DraftStabilizer(遮住末尾 2 个词 / 3 个字、只增;新措辞连续两次一致才改写,不会冻住)
                  → 暂定译文 = 各段译文 + 尾巴译文(新片段还在翻译时不缩短,不闪)
                  为什么分片段:火山引擎等识别中几乎不打句号,句子要等定稿(实测 10~20 秒)才切得出;
                  整段越来越长的文字反复重翻会让译文开头不停变化(实测暂定译文冻住 10 秒)
              记录路径(AI 翻译):识别中不切句,原文行显示整段未定稿文字
          → .final → 取出 live.startedAt、清空 live → SentenceSplitter.split(final: true)
              → CaptionTranscript.commit(句子, startedAt:)(每句一条 Entry;time = 这段开始说的时刻,没有 live 时 = 现在;
                 finalizedAt = 现在;同一次定稿的句子 time 相同)
              → CaptionFeed.final:分句路径 → CaptionSegmenter.final(用已给出部分的末尾词定位,只补没给出的句子;
                 多段分次定稿时超出部分留给下一段抵扣);记录路径 → 按记录句子生成 unit 并关联
              → 本场开启了翻译(SubtitleController.translationEnabled)→ SubtitleController.translate(记录的句子):
                 AI → TranslationService.translateLine(前 3 句原文 + 译文作上下文)→ TextProcessor.translateSubtitle
                    → LLMClient.stream → .streaming(暂定,同步到字幕条)→ .final
                 系统 / 在线服务 → SentenceTranslator(与字幕条同一句共享结果,不重复请求)
                 → CaptionTranscript.setTranslation(target:) / CaptionFeed.entryTranslation
          → 字幕条点「译」→ SubtitleController.toggleTranslation(翻译成默认语言 AppSettings.subtitleTarget,再点关闭);
            「译」旁 ⌄ 选语言 → subtitleTarget(同时成为默认语言)+ setTranslationEnabled(true);
            每场 start 时重置为关闭(不持久化)
          → 换目标语言 / 翻译方式 → AppState 监听 → SubtitleController.translationConfigChanged
              → SentenceTranslator.reset + CaptionFeed.restartTranslation(旧译文不再显示,最新一句重译)+ 记录最新一句重译;
              代数(translationGeneration / CaptionFeed.generation)丢弃旧设置下返回的结果
 → CaptionFeed.advance(每次新内容 + 每 0.5 秒,同时 LiveDraft.tick 补上停顿时被节流挡住的最后一次)
   → RollingCaptions.update(同传类应用的滚动字幕,Google 重翻译 + 稳定前缀的做法):
     原文行 = 已确认句子 + 正在说的部分(跟着语音实时走,未确认部分略暗);
     译文行 = 按句子顺序:整句译文(到达后锁定)/ 还没定下的句子先用暂定译文 + 末尾接上正在说的半句的暂定译文,
       所以只比原文慢零点几秒;前面连续定下的部分正常显示,从第一处暂定内容起略暗;
     不丢句:一句等整句译文超过 timeout(系统 3 秒 / 在线 8 秒 / AI 15 秒)或失败 → 用暂定译文、没有就用原文顶替;
       只有一句什么都没有时后面的才等它(translationWaiting → 「翻译中…」);
     译文按句分段(translationLines,每句单独起一行,正在说的半句是最后一段):读者的位置总在句首,
       一句的译文变化(暂定 → 整句)只影响它自己那一段,前面已读的句子不重排;最多保留 `RollingCaptions.maxTranslationLines`(40)句,旧句子整句滚出
       (实测连续成段时,暂定译文替换、新行出现会让整段跳动,用户反馈"一滚动就不知道读到哪里");
     原文行:起点固定、只在末尾增长(换行稳定),累计超过 900 字符才按整句移动起点
 → SubtitleSurface:原文在上、译文(加粗)在下,字号各自可调(subtitleSourceFontSize / subtitleTranslationFontSize,
     12–40;标题栏 小 / 大 两个一起调;旧版单一字号按 75% / 85% 换算);行数可调(设置 › 实时字幕:译文 2–5 行,默认 3;
     翻译时原文 0–3 行,默认 2,0 = 只看译文;译文还没有时至少 1 行原文);不翻译时原文 2 行大字;
     译文区 TranslationScrollView(Apple Music 歌词式):每句一段,跟随最新时底部对齐,新句子 / 某段多出约一行时
       平滑滚到底(0.25 秒);亮度按新旧递减(最新 1.0,往上 0.82、0.68),暂定内容 0.55;
       用户用触控板 / 滚轮往回滚 → 停止跟随(鼠标在译文区上时装 NSEvent 本地 scrollWheel 监听,scrollingDeltaY > 0 才算;
       不从滚动位置推断——跟随时程序滚动 / 暂定译文变短引起的位置变化会误判,「回到最新」会闪一下),
       往回看时已定句子都 0.92,右下角「回到最新」;点它、滚回最底部或停止滚动 6 秒 → 恢复跟随;保留最近 40 句;
       原文和提示不接收鼠标事件,译文区接收(锁定字幕条时整块穿透,只能跟随);左对齐;
     顶部淡出(被裁掉一半的旧句子渐隐,表示上面还有内容);
     透明窗口高 480(放得下最大字号下 3 行原文 + 5 行译文),只有字幕条区域接收鼠标;
     有字幕后宽度固定(宽度变化会让换行重排);标题栏只在悬停时出现(先加宽再淡入、先淡出再收窄);
     字幕文字 allowsHitTesting(false),不挡标题栏按钮;翻译出错 / 当前方式不可用时在译文位置说明原因
 → 标题栏:TranslationTargetChip(「译」/「译 · 语言」点一下开关,旁边 ⌄ 选语言)+ TranslationMethodChip(开启翻译后出现:
     系统翻译 / 已配置的在线服务 / AI 模型列表(LLMModelCatalog)/ 添加在线翻译服务 → WindowManager.showSettings(.translation, configure:))
     + SourceLinesChip(开启翻译后出现:「原文 N 行」/「只看译文」,菜单选 不显示 / 1 / 2 / 3 → AppSettings.subtitleSourceLines,
       和 设置 › 实时字幕 › 翻译时原文行数 同一个设置)
 → PillView:dictation 空闲且字幕运行、没收起时显示 SubtitleSurface(与胶囊同一个 glassEffectID,变形过渡)
结束(所有入口):AppState.stopCaptions(from: .surface / .command / .device)
 → 开了「结束字幕前确认」(confirmStopCaptions)且不是 Passport:PillPanelController.showStopPrompt(展开字幕条、显示状态条)
   → PillUIState.stopPrompt = StopCaptionsPrompt(应用名、句数、本场 transcript.id)
   → PillView 把它作为 Binding 传给 SubtitleSurface(期间标题栏保持显示,气泡才有依托)
   → ⏹ 按钮上 AnchoredPopover(深色 NSPopover,小三角对着 ⏹)弹出 StopCaptionsBubble(TipKit 风格:图标 + 标题 + 说明 + 不再询问 / 取消 / 结束)
   → 「结束」→ PillActions.confirmStopCaptions → AppState.confirmStopCaptions(勾了「不再询问」就关掉设置;
     再核对还是发起时那一场字幕)→ finishCaptions;「取消」/ 点外面 / Esc → popover 关闭 → Binding 置 nil → cancelStopCaptions
   气泡已显示时:字幕条 ⏹ 再点一次 = 取消;菜单 / 快捷键再触发一次 = 确认(键盘用户不用去点气泡);
   Passport 上结束不确认(设备上没法回答),已显示的气泡直接收起并结束
 → finishCaptions:SubtitleController.stop(未定稿的半句 live 以它的开始时间 commit 进记录)→ AppAudioTap.stop → ASRSession.cancel
 → 结束后字幕记录窗口没在显示 → WindowManager.showTranscript(.captions)(Passport 发起的不激活 VibeKey);保存、总结由用户在窗口里处理
正在转录时选了别的应用:AppState.startCaptions → 当前记录有未保存内容 → CaptionsConfirmation.confirmSwitch
 (「切换」(破坏性)/「打开字幕记录」(不切换,先去保存)/「取消」;不受「不再询问」影响)→ stop → start(新的一场);没有未保存内容直接切换
窗口「保存…」→ TranscriptSaver.save(in: window)→ NSSavePanel → CaptionTranscript.plainText(summary: 总结在前)→ 写 UTF-8 文本
退出 app:AppDelegate.applicationShouldTerminate → AppState.prepareToQuit(字幕在进行时 CaptionsConfirmation.confirmQuit,取消则不退出)
(换应用、退出会丢记录,仍用模态提示框打断一次;结束字幕只是确认,用字幕条上的气泡,不打断)
```

字幕记录(app 不保存任何历史,记录只在内存里,下次开始字幕或退出后清除):

```
字幕条 📄 / ⌃ 菜单与菜单栏「字幕记录…」/ 结束字幕后自动打开 → WindowManager.showTranscript
 → TranscriptView(只读 SubtitleController.transcript / live,跟随最新自动滚动)
     「拷贝全部」→ CaptionTranscript.plainText → NSPasteboard
     「保存…」→ WindowManager.saveTranscriptFromWindow → TranscriptSaver.save(in: window)(表单形式的保存面板)
 正文 TranscriptTextView(NSTextView,只读可跨行选择;只重排变化的尾部,译文异步到达时不重建整篇;showTranslations 切换时重建)
     按段显示:CaptionTranscript.paragraphs()(time 相同的相邻句子 = 同一次定稿 = 一段,只显示一个时间)
       → text(of:) / translation(of:)(TranscriptText.join 拼接)→ render;数据仍按句保存,翻译 / 润色按句;
       拷贝 / 保存(plainText)用同样的分段
     正在说的一段:live → render(offset: offset(of: live), live: true)——一出现就带时间,正文浅色;
       定稿后从同一位置重排成正常段,时间来自同一个 startedAt,只换颜色、不跳位置(Otter / Zoom 式实时转录)
 顶栏:标题 | 字幕 / 总结 切换 | 固定、跟随最新(仅字幕页);左右两侧等宽,切换控件始终居中、切页不偏移
 「字幕」页顶部 TranscriptTranslationBar(字幕进行中或结束后都可用,不会自动开始;和字幕条一样「选语言 = 翻译」):
     语言菜单(还没有译文时标签是「翻译」,有译文时「译文:语言」)选一个语言
       → targetOverride(默认跟随字幕条)+ showTranslations = true + translateMissing
         (没有译文 / 失败 / 译文不是所选语言;实时翻译定稿 10 秒内(Entry.finalizedAt)的新句子交给它)
     「显示译文」(有译文时才出现)→ showTranslations(拷贝 / 保存也按它)
     方式菜单(TranslationMethodMenuItems,target = 窗口所选语言)→ methodOverride(默认跟随设置);
       在这里添加在线服务 → 设置 › 翻译服务 的配置表单,保存后设为字幕的翻译方式(useFor: .subtitles)
     ⋯「翻译未翻译的句子(N 句)」→ translateMissing;「全部重新翻译」→ retranslateAll;
       「AI 润色译文」→ polish(已有本语言译文、还没润色过的句子)
     出错行「检查配置…」→ 按出错的任务 / 当前方式直接打开对应配置(语言包 / 服务表单 / AI 服务)
       → TranslationService.plan(BatchPlanner)→ 固定数量的工作任务(并发 = BatchLimits.maxConcurrent)
          → translateChunk(在线服务 / 系统 / AI 编号批量 Prompts.translateBatch → NumberedLines;对不上时逐句)
          或 refine(Prompts.refineTranslations,每块 12 句 + 前 3 句上下文)→ RequestGate
       → ResultWriter 每 0.3 秒 → SubtitleController.applyTranslations(只写回同一场)→ CaptionTranscript.setTranslations
       → 进度条「翻译 32/120」+「取消」;密钥 / 额度 / 时间错误停止整批并显示原因,其他错误只标记那几句失败
     新的一场字幕 → resetIfNewSession(复位选择、取消任务)
 「总结」标签页 → SummaryView(出现 / 消失 → TranscriptSummarizer.setTabVisible)
     WindowManager.showTranscript / windowWillClose / 最小化 → setWindowVisible
     isActive = 窗口开着 && 停在总结页 && TranscriptSummarizer.enabled(每场新的字幕默认关闭);不满足 → 暂停定时检查并取消进行中的请求
     定时检查(5 秒)→ 距上次(或打开开关时)≥ summaryInterval 分钟且新内容 ≥ 4 句(字幕结束后剩余内容也总结)→ summarize
     SummaryView 底部用 nextSummaryAt 显示倒计时(TimelineView 每秒刷新;到点但内容不够时显示"等待更多内容")
       → AppSettings.summaryLLMConfig(接口和 Key 只来自 设置 › AI 的服务;模型可在总结页从该接口的模型列表另选,默认跟随)
       → Prompts.summarize(用户主语言,2–5 条要点)+ summaryUser(新内容 + 上一段总结作上下文)
       → LLMClient.stream(边生成边显示)→ sections;「立即总结」→ summarizeNow
     「总结全文」→ summarizeAll:全文 ≤ 12000 字直接总结;更长时 chunks → Prompts.summaryNotes 逐块整理要点
       → Prompts.summarizeAll(概述 + 要点 + 结论 / 待办)→ LLMClient.stream → fullSummary(卡片置顶);不受暂停规则影响
     每段时间范围:开始 = 第一句开始说的时刻(Entry.time),结束 = 最后一句的定稿时刻(Entry.finalizedAt)
     新的字幕会话开始 → 清空总结(只在内存里)
 📌 → TranscriptPinController.toggle:固定 = 贴屏幕右边占满可用高度、floating 层级(始终最前)、所有桌面空间可见、不可拖动,
     窗口透明 + 深色外观,TranscriptView 画和字幕条一样的深色玻璃;
     取消 = 恢复普通层级、不透明背景和之前保存的位置;状态存 UserDefaults,屏幕参数变化时重新贴边
```

## 6. 胶囊状态条与字幕交互

形态由纯函数 `PillPresentation.surface` 决定(有单元测试覆盖每条规则):

| 条件 | 形态 | 可做的事 |
| --- | --- | --- |
| 听写录音 / 处理 / 结果 | 听写形态(优先级最高) | 听写进行时字幕在后台继续采集,解码暂停(`SubtitleController.setDecodingPaused`),结束后补上 |
| 字幕启动失败 | 字幕条(只显示原因和 ✕ 关闭) | 关闭 → `AppState.stopCaptions` |
| 字幕运行且展开 | 字幕条 | 「译」标签:选语言开启 / 再点当前语言关闭;翻译方式标签(开启后出现):方式与 AI 模型;原文行数标签(开启后出现):翻译时原文 0–3 行;悬停:字号、锁定、📄 字幕记录、🎤 听写、⌄ 收起、⏹ 结束 |
| 悬停,没有字幕 | 工具条 | 🎤 听写;◉ 弹出应用列表(`MenuBuilder.captionAppsMenu`)选择后开始;⌃ 菜单 |
| 悬停,字幕已收起 | 工具条 | ◉ 展开字幕条;结束、字幕记录在 ⌃ 菜单 |
| 不悬停 | Agent 通知 / 细胶囊 | 字幕在后台运行时细胶囊带红点 |

开始字幕的所有入口(胶囊 ◉、开关字幕快捷键、菜单栏、Passport 字幕模式)都先选择应用(设置页不再放应用列表),然后调用 `AppState.startCaptions`(展开字幕条 → `SubtitleController.start`);不沿用上次的应用。
正在为某个应用生成字幕时选择另一个应用:`AppState.startCaptions` 在上一场记录有未保存内容时弹切换确认框
(`CaptionsConfirmation.confirmSwitch`,可以选「打开字幕记录」先保存),确认后 stop → start;开始新的一场会替换上一场记录;
选的是正在转录的同一个应用时只展开字幕条,不重新开始(不清空记录)。

启动规则(`SubtitleController.start`):每次 start / stop 递增 `generation`,启动任务(加载模型 / 连接云端)完成时代数变了就丢弃会话,
不会出现两场同时运行;音频采集启动失败时关闭已建立的识别会话。启动失败(模型不可用、没有系统音频权限)时 `needsSurface` 为真,
字幕条显示原因(`ModelManager.unavailableMessage` 区分"未下载"和"未配置"),只有 ✕ 关闭,点了走 `stopCaptions`(不询问保存)。
设置里隐藏了状态条时,字幕运行 / 失败 / 选择字幕应用期间仍强制显示(`PillPanelController.show(force:)`),结束后恢复隐藏。
听写进行中才开始的字幕:会话进入 running 时按 `dictation.phase` 立即暂停解码。
结束字幕的所有入口都调用 `AppState.stopCaptions`。字幕条锁定(穿透)后,收起 / 展开 / 结束、本场翻译的开关 / 翻译成 / 翻译方式
(`MenuBuilder.translationItems`,和字幕条「译」标签是同一个开关)都可以在菜单栏和 ⌃ 菜单里操作,不会走进死胡同。

空闲胶囊:`IdleCapsule` 呼吸(Core Animation 循环,尊重"减少动态效果");`PillView.task(id: activityKey)` 计时,
30 秒无活动 → dimmed(内芯降低亮度、玻璃换 clear 样式),任何状态 / 悬停变化立即恢复。


```
PillPanelController.startMouseTracking → updateHover(热区来自 PillView.reportHotRect)
 → PillUIState.isHovering → PillView.updateExpanded(延迟收起)
 → PillView.pill:按 DictationController.phase 加字幕和 Agent 状态选择形态
点击 → PillActions(AppState 注入)→ DictationController.toggle / SubtitleController / MenuBuilder.build → popUp
  (PillPanelController.popUp:按菜单尺寸算左上角,菜单底边贴着按钮顶部、水平居中、不遮住胶囊;
   SwiftUI 托管视图是翻转坐标(y 向下),左上角 = 按钮顶部 − 菜单高度;按非翻转坐标算会差出整个窗口高度)
拖动 → DragGesture → PillWindowActions.dragChanged/dragEnded → PillPanelController 移动窗口并保存偏移
回到底部中央:菜单「状态条回到底部中央」/ 快捷键(KeyboardShortcuts .resetPillPosition,默认未设置,设置 › 快捷键 录制)
  → HotkeyManager.Actions.resetPillPosition → AppState.resetPillPosition → PillPanelController.resetPosition(清除偏移,放到鼠标所在屏幕)
菜单栏图标:StatusMenuController(NSStatusItem.menu 常驻,系统负责在被点的那块屏上定位)
  → 打开前 NSMenuDelegate.menuNeedsUpdate → MenuBuilder.build(和 ⌃ 菜单同一份内容)→ 菜单项搬进常驻菜单
  (macOS 27 多显示器已知系统问题:图标在另一块屏被收进 `<<` 溢出区时,在那块屏点一下再回原屏点图标,
   系统按过期的状态项窗口位置弹菜单而偏离图标;同样收在溢出区的其他应用也一样,不在 app 里自行计算位置)
```

## 7. Agent 通知(vibe coding)

```
Claude Code hook:open -g 'folobutton-dev://agent?event=…'
 → AppDelegate.application(_:open:) → AppState.handle(url:)
 → AgentNotifier.handle(url:) → 入队 / 显示
     ├─ current → PillView.agentPill(胶囊或字幕条上方)
     └─ onNotice → DeviceBridge → DeviceLink.sendAgent → 设备通知层与提示音
一键配置:VibePane.AgentHookRow → AgentHookInstaller.install(.claudeCode | .codex)
 → 读取并备份 ~/.claude/settings.json | ~/.codex/hooks.json → 合并同一格式的 hooks(去重)→ 写回
   Claude Code:Stop / Notification / UserPromptSubmit;Codex:Stop / PermissionRequest / UserPromptSubmit
   (Codex 需在 CLI 里 /hooks 信任新命令;不改动 Codex 的 notify 设置)
```

Codex 续聊：`Stop` Hook 从 stdin 提取会话 UUID、轮次 ID 和裁剪后的项目名,原位升级旧命令。通知按轮次去重,最多排队 8 张,当前完成卡显示 15 秒。短按 OK 松开或点击 Mac 胶囊 → `DeviceBridge.openNotice → CodexThreadNavigator.open` → 用官方 `codex://threads/<UUID>` 打开并聚焦输入框 → 通过默认 ⌘⌥L 读回当前会话链接、核对 UUID 与输入目标,按原剪贴板代次恢复内容。成功显示 `READY TO TALK`,失败显示 `OPEN CODEX`。该按压只负责打开。

打开后按住 OK → 采音并确认此时前台 Codex 的 AX 输入目标，同时读取可用的会话 UUID。手动切换后下一次录音绑定当前对话。新对话尚无 UUID 时也可绑定已核对的输入框。松开识别 → 粘贴前再次核对录音开始时的输入目标和会话链接状态，避免录音期间切页写错位置。短按上键也要核对目标后才发送。打开完成卡后最多暂缓后续完成通知 20 秒，给下一次 OK 留出时间。期间发送成功或打开失败会立即恢复队列。长按下键退出绑定、恢复原应用选择动作，也会立即恢复队列。停在草稿时，暂缓到期也会自动继续显示，草稿仍留在原对话。Hook 与设备协议均不传输对话正文、绝对项目路径或审批详情,会话 UUID 只留在 Mac。 [Codex Hooks](https://learn.chatgpt.com/docs/hooks) · [会话深链接](https://learn.chatgpt.com/docs/reference/commands#chats)

## 8. 模型下载

```
ModelCard「下载」→ ModelList → ModelManager.download(id)
 ├─ Whisper:withHostFallback(官方源 / 镜像)→ WhisperKit.download → 写 .installed 标记
 ├─ SenseVoice:withHostFallback → FileDownloader.download(model.int8.onnx, tokens.txt)→ 写标记
 └─ Apple Speech:AssetInventory.assetInstallationRequest → downloadAndInstall
 → states[id](进度)→ ModelCard 进度环
切换模型 → AppSettings.dictationModelID → AppState.observeSettings → EngineRegistry.unloadAll / preload
```

## 8a. 云端识别配置

```
设置 › 模型「云端识别」/ 引导模型页 → ModelCard「配置」(未配置)或 ⚙(已配置)
 → ModelList.editing → CloudConfigSheet(provider)
     → CloudASRStore.config(provider)(API Key 来自 CredentialStore,其余来自 UserDefaults)
     → 模型:ModelPickerField(选项 = CloudASREngine.fetchModels:
         OpenAI 兼容 → 地址和 Key 填好后停顿 0.6 秒 → OpenAICompatibleAPI.listModels → transcriptionModels 过滤;
         Soniox → Key 填好后停顿 0.6 秒 → SonioxAPI.realtimeModels(GET /v1/models,只留 real_time、去掉别名);
         其他服务没有列表接口 → CloudProvider.knownModels(官方文档列出的实时识别模型 / 资源 ID))
     → 「测试连接」CloudASREngine.test → 1.5 秒近静音 → 有 .failure 则显示原因
     → 「保存」CloudASRStore.update → CredentialStore.set("cloud.<provider>.apiKey") + UserDefaults
 → ModelManager.state(cloud-…) == .installed(配置齐全即"可用")→ 可选为听写模型 / 字幕模型
听写和字幕各自选模型:AppSettings.dictationModelID / subtitleModelID(字幕选项里列出所有可用模型,含云端)
密钥:~/Library/Application Support/FoloButtonDev/credentials.json(0600,仅当前用户可读);
旧版本存在钥匙串里的 LLM Key 在首次启动时静默迁移一次(不弹授权框,UserDefaults 标记只跑一次),之后删除钥匙串条目
```

## 8b. 翻译方式与在线翻译服务

翻译在两种场景里工作,各自一个翻译方式(`TranslationMethod`,每种场景一次只用一种):
实时字幕(及字幕记录窗口的默认值)= `AppSettings.subtitleTranslationMethod`;听写翻译 = `dictationTranslationMethod`。
`system` = 系统翻译;`provider(…)` = 在线机器翻译(DeepL / Google / 微软 / 火山引擎 / 腾讯云 / 百度);`llm(model:)` = AI(模型为空跟随设置)。
迁移:上一版共用的 `translationMethod`、更早的 `translationEngine`(hybrid / system → system,llm → llm)作为两个场景的初始值,
立即保存新键并删除旧键;全局开关 `subtitleTranslate` 删除。
`TranslationService.isAvailable(method, target:)` / `unavailableReason`:系统 = 该目标语言对的语言包已下载
(`systemStatuses` 按字幕和听写的目标语言各查一次;还没查完的「正在检查语言包…」先算不可用,翻译前 `ensureSystemStatus` 会先查一次);
在线服务 = 密钥齐全;AI = LLM 已配置。
AI 实时翻译和批量 / 润色一样经 `RequestGate`(并发 2);一次定稿的几句由 SubtitleController 串行翻译(后一句的上下文里才有前一句的译文)。
在线服务超时按请求规模(10 + 字符数 / 500 秒,最多 30 秒);限流按 `Retry-After` 等待后重试一次。
翻译中途出错(额度用完、密钥失效):`CaptionFeed.translationError` 在字幕条译文区下方常驻说明,翻译方式标签显示 ⚠,下一次成功后清除。
目标是简体中文时译文统一转简体(`TranslationService.normalized`,系统翻译偶尔混出繁体字)。

```
设置按"用户在哪个场景想到它"组织(SettingsView.Pane):通用 / 听写 / 实时字幕 / 识别模型 / 翻译服务 / AI 服务 / 快捷键 / 词汇表 / Passport / Vibe
 设置 › 听写(DictationPane):「AI 润色」开关 + 润色模型(LLMModelMenuItems → AppSettings.polishModel);
   「听写翻译」TranslationMethodSettingRow(.dictation,按听写目标语言判断可用性)+ TargetLanguageSettingRow;
   说明文字里的「快捷键」「词汇表」是应用内链接(vibekey-settings://<pane>,View.settingsLinks)→ 跳到对应设置页
 设置 › 实时字幕(SubtitlesPane):识别(字幕使用的模型 → AppSettings.subtitleModelID,默认与听写相同)/
   显示(译文字号、原文字号、译文行数、翻译时原文行数、锁定)/
   「翻译」TranslationMethodSettingRow(.subtitles)+ 默认翻译成 + 边说边译 / 字幕记录
   两个场景的「翻译方式」都用 TranslationMethodMenuItems(和字幕条同一个菜单);当前方式不可用时在该行橙色说明原因
 设置 › 识别模型(ModelsPane):下载 / 切换听写模型、云端识别配置、国内镜像下载(字幕用哪个模型在「实时字幕」页选)
 设置 › 翻译服务(TranslationPane):只负责配置,每行常驻「配置」,标出「实时字幕在用」「听写在用」:
   系统翻译「配置」→ SystemTranslationSheet(字幕 / 听写目标语言的语言包各一行,SystemTranslationRow)
   在线服务「配置」→ TranslationProviderSheet;AI「配置」→ 设置 › AI 服务
   跨页入口统一走 SettingsNavigation.configure(provider, useFor:) / configureSystemTranslation()
入口:服务列表「配置」/ 场景方式菜单「添加在线翻译服务」/ 字幕条方式菜单「添加在线翻译服务」
   (WindowManager.showSettings(.translation, configure:, useFor: .subtitles))/ 字幕记录方式菜单;
   系统翻译语言包没下载时,各方式菜单里显示「系统翻译(离线)· 下载语言包…」→ showSettings(.translation, systemTranslation: true)
 → TranslationProviderSheet:按 TranslationProvider.fields 填写(Key / Secret / 区域)
     → 「测试连接」MachineTranslatorFactory.test(把一句话译成用户主语言,显示译文)
     → 「使用此服务:☐ 实时字幕 ☐ 听写翻译」(默认勾上正在用它的场景 + 从哪个场景进来的 SettingsNavigation.providerUse)
     → 「保存」MachineTranslationStore.update → CredentialStore("translate.<服务>.key / secret")+ UserDefaults(区域)
        → 按勾选设置两个场景的方式;取消勾选正在用它的场景 → 退回系统翻译;「移除配置」后正在使用的场景退回系统翻译
调用:TranslationService.translateBatch → BatchPlanner(本机识别源语言 → TargetLanguage.resolvedTarget → 同语言跳过 → 按语言对分组切块)
 → translateChunk → MachineTranslatorFactory.make → RequestGate(各服务一个,并发 + QPS)
 → *Translator.makeRequest(ProviderLanguageCodes;DeepL / Google / 微软:Key 放请求头(Google 用 X-goog-api-key,不进 URL);火山:VolcengineSigner;
     腾讯:TencentTC3Signer;百度:MD5 签名,多句用换行拼接、按 src 回配拆行 / 吞行的结果)
 → MTHTTP.send(超时按请求规模;网络错误 → transient;读 Retry-After)→ parse(结果条数校验 + 错误归类)
 → 限流 / 临时故障重试一次;密钥 / 额度 / 时间错误(abortsBatch)直接报给调用方
调试:IB_SETTINGS_PANE=translation IB_TRANSLATE_CONFIG=<服务> 直接弹出配置表单
```

语言包:`TranslationService.refreshSystemStatus`(启动、目标语言变化、app 重新激活时)→ `SystemTranslator.status`;
下载:`SystemTranslationRow`「下载」→ `.translationTask` → `prepareTranslation()`(系统弹窗确认)→ `systemDownloadFinished`;
或「在系统设置中管理」→ 系统设置 › 通用 › 语言与地区 › 翻译语言。

翻译目标语言(`TargetLanguage`,听写和字幕各一个,默认 `auto`):
`auto` → `TargetLanguage.autoPair`(系统首选语言 P + 另一种语言:英语,P 是英语时取第二首选语言或简体中文)
→ AI:`Prompts.target` 提示词"译成 P;原文已经是 P 就译成另一种语言";
   系统 / 在线服务:按句识别源语言 → `resolvedTarget`(原文是 P 译成另一种语言,否则译成 P)→ 各家语言代码。

## 8c. AI 服务(LLM 配置)

接口和 Key 只在一处配置(设置 › AI 服务),各功能各选模型:听写润色 `polishModel`、AI 翻译 `.llm(model:)`、
字幕总结 `summaryModel`;空 = 默认模型 `llmModel`。模型菜单统一用 `LLMModelMenuItems`(LLMModelCatalog 提供列表)。
设置 › AI 服务(AIPane)下方列出使用它的功能、各自的模型,「前往」跳到该功能的设置。
菜单栏 / ⌃ 菜单「听写后 AI 润色」(写明是听写;没配置 AI 服务时显示「…（需要配置 AI 服务）…」并打开 AI 服务设置)。

```
设置 › AI 服务 / 引导 AI 页 → LLMConfigForm
 → 服务商预设 → AppSettings.llmBaseURL / llmModel
 → 地址或 Key 变化 → .task(id:) 停顿 0.6 秒 → OpenAICompatibleAPI.listModels(GET /models)
     → ModelPickerField 下拉选择(当前值不在列表里也保留显示;"手动输入…"切换成文本框;失败时显示原因并可手动输入)
 → 「测试连接」LLMClient.complete(一句 ping)
```

## 9. 一键刷固件 / 更新固件

app 不内置固件,只内置 esptool(Resources/DeviceAssets/Tools);固件刷写时从官网下载,官网网页刷写用的是同一份清单。

```
发布:firmware/build → scripts/package-firmware.sh(检查地址 < cardid,算 SHA-256)
 → firmware/build/release/{manifest.json, <ver>-<build>/*.bin} → website/deploy/deploy.sh → https://input.0os.io/firmware/

PassportSetupView 出现 → PassportSetupModel.checkFirmware → FirmwareFlasher.checkLatest(10 分钟内不重复)
 → FirmwareDownloader.fetchManifest → FirmwareManifest.isCompatible(proto == DeviceMessage.protocolVersion)
 → FirmwareFlasher.latest(.available / .incompatible / .failed)

PassportSetupView「刷入固件」→ PassportSetupModel.flashFirmware
 → FirmwareFlasher.flash(port:) → run
     → FirmwareDownloader.fetchManifest → record(协议不一致 → FirmwareError.incompatible,提示先更新 app)
     → FirmwareDownloader.download → FirmwareManifest.parts(芯片 ESP32-C3、地址 < cardid 0x356000、不重叠、
        相对路径不越出清单目录)→ 下载到 ~/Library/Caches/FoloButtonDev/Firmware/<ver>-<build>/,逐个校验大小与 SHA-256
        (已缓存且校验通过的跳过)→ phase .downloading(USB 链路此时照常工作)
     → write:DeviceLink.suspendUSB(让出串口)→ 再次确认本机文件地址 < cardid
     → EsptoolRunner.run(read-mac)→ EsptoolRunner.mac
     → ensureBackup:已有备份则跳过,否则 EsptoolRunner.run(read-flash 8 MB)→ 校验大小
     → EsptoolRunner.run(write-flash 三个镜像,不传 flash 参数即保持镜像头里的值,不擦除整片)→ EsptoolRunner.progress → phase
     → DeviceLink.resumeUSB → 重新握手 → PassportSetupModel.stage == .connected
设备识别:DeviceLink.handleHello(固件名不符)/ 握手超时 → handshakeFailed → foreignDevice → stage .needsFirmware
是否需要更新:DeviceLink.firmwareBuild(hello 的 build)≠ FirmwareFlasher.latestManifest.build(官网清单,取自 app.bin 0xB0)
 → PassportSetupModel.firmwareUpdateAvailable → 「更新固件」;相同则显示「重新刷入」(都用 DeviceLink.usbPortPath)
刷写期间 PassportSetupModel.stage == .flashing(USB 暂停,不按连接状态判断)
调试:IB_FIRMWARE_MANIFEST=<url> 改用别的清单地址;IB_FLASH_FIRMWARE=1 连上 USB 后自动刷一次

官网网页刷写(/passport/#firmware,website/site/assets/flasher.js,不用 ESP Web Tools:它全新安装时默认擦除整片 Flash,会抹掉 cardid):
「连接并刷入」→ navigator.serial.requestPort(VID 0x303A)→ fetchManifest → partsOf(与 FirmwareManifest 相同规则)
 → download(大小 + SHA-256)→ esptool-js ESPLoader.main → 芯片 ESP32-C3 / Flash 8MB / 分区表有 cardid@0x356000,否则停止
 → (可选)readFlash 整片 8 MB 存成 passport-<MAC>-flash.bin → writeFlash(eraseAll: false,flash 参数 keep)→ after(hard_reset)
```

## 9a. 离线页自定义壁纸

```
设置 › Passport › 离线页背景
 → fileImporter 选图 → WallpaperProcessor.process(url:)
     → CGImage 3:4 居中裁切 → 60×80 降采样 → 亮度 + Bayer 抖动 → 24 级绿色
     → 顶部 40 px / 底部 y=200 起压暗 → 4×4 放大成 240×320 预览
     → 240×320 RGB565 小端、行优先输出(153600 字节)
 → WallpaperSection.apply → DeviceLink.uploadWallpaper
     → wallpaper start(size,crc) → 等设备回 p:"start"(擦除完成,15 s 超时)
     → 每块 288 字节 base64,off 递增,每块 6 ms 节流
     → wallpaper fin=1 → 设备校验长度 + CRC32、写头、回 p:"done"、500 ms 后重启
 → WallpaperStore.save(240×320 预览 PNG)

固件启动:ib_app_start → ib_wallpaper_init
 → esp_partition_find_first(data, 0x40, "wallpaper")
 → esp_partition_mmap(头 + 153600 字节) → 校验 VKW1 / size / CRC32
 → ib_ui_offline.create 用映射指针构造 lv_image_dsc_t;无效则用 ib_offline_art.inc 内置猫图
```

壁纸分区 `0x310000/0x30000` 在 factory 与 cardid 之间；写头放在最后，断电或分块中断只会让 CRC 失效并回退默认图。Mac 端不保存用户原图，只保存处理后的预览；原图与像素数据都不进仓库。

## 10. 界面语言

```
LanguagePicker(设置 › 通用 / 欢迎页)→ LanguageState.set(即时生效,不重启)
 ├─ AppLanguage.save → 本 app 的 AppleLanguages 偏好(下次启动沿用)
 ├─ L10n.use → 切换当前语言的 .lproj 资源包(Bundle.l10n)
 └─ locale 变化 → LocalizedRoot 注入 \.locale 并按 locale 重建视图树(设置 / 引导 / 状态条)
     → WindowManager 同步窗口标题;菜单每次打开时重新生成
文字来源:SwiftUI 字面量(按 \.locale 查找)/ String(localized: …, bundle: .l10n)(模型、枚举、错误)
 / ModelCatalog.all 每次访问时生成
 → Localizable.xcstrings(源语言简体中文,英文来自 app/Localization/en.json,由 scripts/update-strings.sh 生成)
系统权限弹窗文字:InfoPlist.xcstrings
```

## 10a. 窗口显示(设置 / 引导 / 字幕记录 / 软件更新)

```
菜单「设置…」/ 字幕条「翻译设置…」(.translation)/ 总结页「设置」(.ai)→ WindowManager.showSettings(pane, configure:) → present
 → NSApp.setActivationPolicy(.regular)(菜单栏应用在 macOS 14+ 协作式激活下单纯 activate 偶尔不前置)
 → 下一轮事件循环(等菜单关闭)→ NSApp.activate → makeKeyAndOrderFront + orderFrontRegardless
WindowManager.showUpdate → 软件更新窗口同样经 present 前置
windowWillClose → restoreMenuBarMode(没有其他打开 / 最小化的窗口时切回 .accessory)
```

## 10b. 检查更新

```
接口配置:Config/App.xcconfig 的 IB_UPDATE_FEED_URL / IB_UPDATE_APP_ID(本机 Config/Update.local.xcconfig 填写,不提交)
 → Info.plist 的 IBUpdateFeedURL / IBUpdateAppID → UpdateFeeds.make
     有 HTTPS 地址 → AppUpdateKit.JSONUpdateFeed(GET 地址?platform=macos,可带 X-App-ID);没有 → nil(开源版默认,不检查、不显示入口)
     调试:IB_UPDATE_FEED 换地址,IB_UPDATE_DEMO=available|required 用 StaticUpdateFeed 假数据
 → AppState.updates = UpdateChecker(feed, 当前版本 CFBundleShortVersionString + CFBundleVersion)
AppState.launch → updates.present = WindowManager.showUpdate;updates.start
UpdateChecker(主线程):启动 5 秒后检查一次;之后每小时看一次,距上次检查满 24 小时(UserDefaults AppUpdateKit.lastCheck)且开着自动检查才检查
 → feed.fetch → UpdateVerdict.evaluate(current, result)(规则与 0os Console shared/versions.ts 一致:
     缺的段按 0、同版本比构建号;版本 ≤ requiredAtOrBelow 且确有更新的版本 → required)
 → required:每次都提示;available:未跳过的版本才提示(手动检查总是提示);upToDate / 失败:只在手动检查时提示
WindowManager.showUpdate
 ├─ .update → UpdatePromptView 窗口(可选:下载 / 稍后 / 跳过此版本;强制:下载 / 退出,无关闭按钮、浮动层级)
 │     下载 → NSWorkspace.open(下载地址);跳过 → UpdateChecker.skip(写 AppUpdateKit.skippedVersion)
 │     强制窗口:observeChanges(updates.verdict) 不再是 required(后台撤销强制)时自动关闭
 └─ .upToDate / .failed → NSAlert
入口:设置 › 通用 › 关于与更新(AboutSection:版本、最近一次结论 + 查看、检查更新、自动检查开关)、菜单「检查更新…」
后台:官网版的接口是 input.0os.io/api/update,由官网 Caddy(本机 website/deploy/private/routes.caddy)转给 0os Console 的 GET /v1/app/update
```

## 11. 设置联动

```
AppSettings(didSet 写 UserDefaults;API Key 写 CredentialStore)
 → AppState.observeSettings(observeChanges)
     showPill → PillPanelController.show/hide
     deviceBluetooth → AppState.updateBluetooth → DeviceLink.bluetoothEnabled
     dictationModelID / subtitleModelID → EngineRegistry.unloadAll / preload(换字幕模型也回收旧引擎)
     language → ModelManager.languageChanged
     subtitleTarget / subtitleTranslationMethod → SubtitleController.translationConfigChanged(翻译中才重译最新一句;
         和上次翻译时的设置相同则不动,「译」菜单选语言先写设置再开翻译不会翻两次)
     subtitles.status → PillUIState.subtitleCollapsed 复位 / PillPanelController.show
     dictation.phase → SubtitleController.setDecodingPaused(听写优先,字幕暂停解码)
```

### 本分支构建兼容性

系统翻译会话使用 macOS 26 SDK 的标准初始化方法,使用系统默认策略;不再依赖更新 SDK 才提供的低延迟参数。构建脚本保留 `pipefail`,仅在 xcodebuild 成功且可执行文件存在时复制 app。

### Codex 当前聊天控制

`AccessibilityCodexDesktopAdapter` 优先从应用的 `AXFocusedUIElement` 读取当前 Codex 输入框。新版 Codex 的 `AXTextArea` 可能不出现在窗口子节点树中，因此不再只依赖遍历 `AXTextArea`；应用级焦点缺失时才回退到唯一 text area。若 `AXValue` 与 `AXPlaceholderValue` 相同，则按空输入框处理。输入框全文只保存在内存用于发送前核对，不写日志或磁盘。聊天身份优先使用 AX 文档、URL 或 Identifier 中的完整线程 UUID；当前版本未暴露这些字段时退回窗口标题。运行、审批与点击判断只采用 enabled 且未 hidden 的按钮，避免树中保留的后台控件污染状态。发送前同一份 AX 快照核对窗口、输入框、全文和唯一可用发送按钮，再重新聚焦并核对目标，向指定进程发送一次 Cmd-Enter；停止仍使用核对后的 AXPress。发送不会在 AX 失败后盲发按键，也不会 AXPress 后再补键。辅助功能未授权时只向设备返回 `ALLOW AX`；只读预检不弹系统授权框，权限申请由设置页的明确操作发起；Codex 未运行返回 `OPEN CODEX`，不再与输入框状态混用。

调用链：

```
Passport OK down → DictationController.pressDown(pushToTalk)
 → PassportMicSource / MicSource → ASR
Passport OK up → ASR.finish → 词汇纠错 → 润色或听写翻译 → TextInserter.insert
 → 在开始录音时的前台应用输入文字，显示 TYPED；不自动发送

Passport UP → CodexActionCoordinator.send
 → 显式接纳当前输入框的手动或语音草稿，绑定目标及 60 秒租约
 → 再读 AX：目标和全文一致、发送按钮可用、已解锁、无待审批
 → 同一快照核对唯一发送按钮 → 聚焦同一输入框 → 再核对目标/全文 → 指定进程 Cmd-Enter 一次
 → 同一聊天输入框清空（允许输入节点重建）才确认 SENT；修改文字本身不是回执
   结果不明：UNSURE，不补发；空输入：INPUT EMPTY；无可用发送控件：BUSY

Passport DOWN → stopCurrent → 核对当前聊天 running、前台、已解锁、无待审批
 → 同一快照中的停止按钮 → AXPress → 核对 idle
   当前没有任务：回到待机页
```

设备的上键映射不再决定录音目标；听写与 Translate 都使用通用语音输入链，因此不会因为 Codex 输入框已有内容或正在运行而在录音起点被拦截。设置里的普通 Enter/Esc 映射仍可显式选用；发送适配器只向完整验证的进程/编辑器提交一次 Cmd-Enter，停止仍点击已识别的 AX 控件，不在 AX 失败时盲发按键。应用切换列表会记住目标并在录音时前置、聚焦；听写翻译服务在 Mac 的翻译设置中配置。

CSS 提示节点也可能进入 Chromium 的 AXValue 和 AXNumberOfCharacters。真机空编辑器的结构为 `AXTextArea.ProseMirror → AXGroup.placeholder → AXGroup → AXStaticText`，提示文字 12 字符加换行形成 13 字符。只有全部文字均处于 placeholder 祖先内才视为空；真实文本、混合段落或嵌入内容始终保留。可用时优先读取 AXStringForRange，纯字符数和 AXPlaceholderValue 用作兼容回退。

### 开发版固件来源保护

`FirmwareFlasher.onlineFirmwareAllowed` 在本分支固定为 false:不查询官网固件、不执行在线刷写。Passport 设置页提示使用受保护的本地脚本,防止上游固件覆盖开发镜像。建立专属固件清单并完成校验之前不启用此入口。

`CodexActionCoordinator` 使用注入的桌面适配器检查焦点、锁屏、输入框全文、运行及待审批状态;读取目标后重新检查草稿有效期,取得一次性租约后发送。发送与停止互斥；适配器点击后无法确认状态变化时按结果不明处理，禁止自动重试。

### 测试宿主隔离

Xcode 测试 scheme 设置 `IB_TEST_MODE=1`,AppDelegate 不启动 AppState、串口、蓝牙与后台服务;普通启动不受影响。避免测试期间抢占连接的真实 Passport。

异步读取桌面状态期间,草稿若被丢弃、替换或追加,发送流程中止;每次变更使用新 generation 防止相同文本的替换被误认为原草稿。

Passport OK 按住触发 `PressInterpreter.pushToTalk`:松开时不满 250 ms 则取消,否则结束并转写;电脑快捷键仍使用原有短按免提。默认 UP/DOWN 映射为 `.codexSend` / `.codexStop`，语音结果先输入当前应用，上键按下时再读取并绑定当前 Codex 草稿；用户改成普通 `.enter` / `.escape` 时仍保留原快捷键能力。已开始的设备按压遇到连接变化时取消,避免松开事件丢失后意外输入。

设备旧版 `approve` 快捷键("1 + Enter")已从设置选项移除且执行层拒绝;已有该映射的设置读取时退回无动作。真正的审批接入仍未实现。Passport 按压时长以系统单调运行时间计算,不受时钟校正影响。

### 产品名、兼容标识与上游数据隔离

产品名是 VibeKey（仓库 `folotoy-vibekey`），但内部兼容标识沿用 `local.folobutton.dev`、`folobutton-dev://`、`_folobutton._tcp` 与 `FoloButtonDev` 凭据、模型、缓存目录：改掉会让系统权限、已安装 hooks 和本机数据失效。新安装的通知 hook 使用独立标识和备份后缀，保留上游已有配置。本机安装版使用稳定 Developer ID 签名，未执行公证。

固件 hello 的 `fw` 新值为 `vibekey`；0.1.7 及更早固件仍是 `inputbetter`，Mac 两种都接受，所以升级 app 不需要先刷机。BLE 广播名从 `InputBetter` 改为 `VibeKey`，只在刷入新固件后生效。

Codex 停止编排要求目标、焦点、锁屏、运行状态及审批状态均匹配,适配器触发前再次核对。结果不明时禁止对该目标重复停止,用户在 Mac 核实后可解除锁定;停止与发送互斥。真实适配器已接入，审批卡出现时仍拒绝发送／停止。

停止结果不明按聊天分别锁定,核实一个聊天不会解锁其他聊天;发送与停止从异步目标检查开始互斥。旧版模拟审批执行层在测试宿主下也不会发送真实按键。

### 正式安装版 Codex 权限诊断

`VibeKeyApp.applicationDidFinishLaunching → CodexAccessDiagnostics.runIfRequested → AXIsProcessTrusted + AccessibilityCodexDesktopAdapter.inspectTarget → 脱敏 JSON → 退出`。显式传入 `--diagnose-codex-access <输出路径>` 时，在正式 App 自身进程中执行；不初始化 AppState，不连接设备、不录音或写输入框。附加 `--followup-thread <UUID>` 时执行真实会话打开和复制链接核对，不提交消息。输出包含权限、安装身份、前台／锁屏、输入字符数和任务状态，不输出输入正文或聊天标题。普通启动不执行诊断。

### 实际语音与翻译诊断

`VibeKeyApp → VoicePipelineDiagnostics` 在显式传入 `--diagnose-voice-pipeline <测试音频> <输出JSON>` 时执行。按正常 DeviceLink / PassportMicSource 读取两秒硬件采样，仅输出采样数、RMS、峰值；用指定测试文件验证当前已安装 ASR 模型，再用固定短句验证当前听写翻译服务。普通诊断不启动窗口或输入文字；显式添加 `--paste-fixture-to-textedit` 时仅向前台 TextEdit 测试文稿写入公开测试结果，其他前台应用一律跳过。调用前先退出常驻 App，完成后恢复常驻连接。

应用菜单的设置命令和 Cmd+, 均进入 WindowManager.showSettings，避免默认 SwiftUI EmptyView 设置场景产生空窗。

### 自动听写翻译的中文方向

自动互译先按基础语言选择方向，简体和繁体中文均从中文译成另一种语言；显式目标仍保留文字体系。NaturalLanguage 对共用汉字短句的简繁判定按实际字形和系统首选中文体系归一化，避免“你好，世界”被误判为繁体后发起不支持的繁体到简体翻译。系统翻译使用已下载的中英文资源；资源下载由 macOS 官方语言管理界面完成。

### 上键连续发送与未知结果恢复

CodexTargetSnapshot.canSend 来自 enabled 且未 hidden 的发送控件；当前任务 running 不等于不能提交。应用允许后续提交/排队时，上键仍可发送；审批中或无可用发送控件时不触发。

回执由 CodexSendReceipt 比较同一进程、窗口、聊天、前台与解锁、无审批以及空输入框；回执阶段可以容忍 inputID 重建，提交前仍要求完整 target 相等。超时仍 UNKNOWN，不自动补发。下一段硬件录音准备好目标且输入框为空时，prepareNewDictation 只清理过时内存状态，不声称旧消息送达；旧文字仍在时继续保留重试锁。

Log.codex 只记录阶段与字符数，不记录草稿、窗口标题或聊天内容。KeySender 的进程定向键事件与全局键事件共用唯一实现，测试宿主始终禁止真实投递。

Electron 控件可见性：DeviceInputTarget 和 AccessibilityCodexDesktopAdapter 在授权后，通过官方 AXManualAccessibility 启用完整 Chromium 控件树，成功结果按进程缓存，不周期性反复开启。从其他全屏 Space 切到 Codex 时，系统切换加 Chromium 首次建树可能超过 2 s；DeviceInputTarget 等待 5 s，并在通用遍历失败后用 Codex 适配器复核，避免把尚未建树误报成无输入框。Codex 的独立 composer 片段还会沿 AXParent 向上补读孩子并去重，保留数量/深度限制。诊断在准备目标后输出控件结构；不将“不含发送按钮的残缺树”误当成应用真的忙。机制见 [Electron 官方文档](https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md#macos)。

AX 遍历按 AXUIElement 的真实相等性去重，不能按 CFHash 的数值去重。窗口与输入框标识由每个适配器拥有的有界匿名注册表提供，同一 AX 元素复用 ID，哈希碰撞的不同元素仍有独立 ID；仅在内存保存，不写入用户文本或磁盘。

连续发送真机验收：2026-11-07 最新安装版在同一常驻进程中，经 Wi-Fi 上键完成三次真实提交，均确认同聊天输入框清空（约 0.4 秒），用户确认成功；无 UNKNOWN。只读检查日志排除了测试宿主，未记录草稿全文。
