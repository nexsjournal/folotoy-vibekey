# InputBetter 架构与功能调用链

本文按功能列出调用链。改动功能时,同步更新对应的链。测试和排查问题时,也从链出发,逐个验证每一环的输入和输出。

## 模块与依赖方向

```
App(AppState 组合根)
 ├─ Hotkey ─┐
 ├─ Pill ───┤ 只读状态、发意图
 ├─ Settings / Onboarding / UI
 ├─ Dictation ──→ Audio ──→ ASR ──→ LLM / Translate ──→ Support/KeySender
 ├─ Subtitles ──→ Audio(AppAudioTap)──→ ASR ──→ Translate(系统翻译 + LLM)
 ├─ Bridge(DeviceBridge / DeviceStateMapper)──→ Device(DeviceLink)
 ├─ Vibe(KeyAction / AgentNotifier / AgentHookInstaller)
 ├─ Models(ModelManager / ModelCatalog)
 ├─ Translate(TranslationService / SystemTranslator / LanguageDetector)──→ Translation 框架 + LLM
 └─ ASR/Cloud(CloudASRStore / CloudASREngine / StreamingCloudSession + RealtimeCodec)──→ Support/CredentialStore
```

依赖规则:

- 下层不依赖上层。
- 跨模块只通过协议或小接口:`AudioSource`、`ASREngine`、`ASRSession`、`SegmentDecoder`、`DeviceLink` 公开方法、`PillActions`、`HotkeyManager.Actions`、`DeviceBridge.Hooks`。

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
| LLM 请求 | `LLMClient.complete` | TextProcessor、LLMConfigForm(测试连接) |
| 设备 ASCII 文本 | `DeviceText.ascii` | DeviceLink 发出的所有命令 |
| 设备状态映射 | `DeviceStateMapper` | DeviceBridge |
| esptool 调用与输出解析 | `EsptoolRunner` | FirmwareFlasher |
| Agent hook 合并写入 | `AgentHookInstaller.install` | VibePane(Claude Code、Codex) |
| 快捷键卡片 | `ShortcutsCard` | 引导快捷键页、设置 › 快捷键 |
| 界面语言选择 | `LanguagePicker` / `LanguageState` / `L10n` | 设置 › 通用、欢迎页,所有根视图 |
| 设备按键提示(图标) | `DeviceStateMapper.keyHints` → `DeviceIcon`、`KeyAction.deviceIcon`、`DeviceIcon.sfSymbol` | DeviceBridge、Passport 示意图 |
| 按键手势识别 | `KeyPressTracker` | DeviceBridge |
| 应用前置聚焦 | `AppSwitcher.activate` | DeviceBridge(切换应用) |
| 密钥存储(本机 0600 文件,不用钥匙串) | `CredentialStore` | AppSettings.llmAPIKey、CloudASRStore |
| 云端流式会话(连接 / 缓冲 / 超时 / 重连) | `StreamingCloudSession` | 火山引擎、百炼、ElevenLabs(各自只实现 `RealtimeCodec`) |
| Float → PCM16 / WAV | `AudioFormats.pcm16` / `AudioFormats.wav` | StreamingCloudSession、OpenAITranscriptionDecoder |
| gzip | `Gzip` | VolcengineCodec |
| 云端服务创建会话 / 测试连接 | `CloudASREngine.session` / `CloudASREngine.test` | CloudASREngine.makeSession、CloudConfigSheet |
| OpenAI 兼容接口地址 / 鉴权 / 错误信息 / 模型列表 | `OpenAICompatibleAPI` | LLMClient、OpenAITranscriptionDecoder、LLMConfigForm、CloudASREngine.fetchModels |
| 模型下拉选择(列表 + 手动输入 + 重新获取) | `ModelPickerField` | LLMConfigForm、CloudConfigSheet |
| 翻译(系统翻译 + LLM 组合) | `TranslationService`(translateLine / quickTranslate / translateDictation) | SubtitleController、CaptionFeed、DictationController |
| 流式识别结果稳定化(LocalAgreement) | `CaptionSegmenter` | CaptionFeed |
| 断句 | `SentenceSplitter` | SubtitleController(记录按句)、CaptionSegmenter |
| 字幕条两行滚动文字 | `RollingCaptions` | CaptionFeed |
| LLM 配置表单(预设 / 地址 / Key / 模型拉取 / 测试) | `LLMConfigForm`(绑定三项配置) | 设置 › AI、引导 |
| 字幕记录分段总结 | `TranscriptSummarizer` | SummaryView |
| 系统离线翻译 | `SystemTranslator`(Translation 框架,会话缓存) | TranslationService |
| 语言识别 / 同语言判断 | `LanguageDetector` | TranslationService、TargetLanguage.resolved |
| 系统翻译语言包状态与下载 | `SystemTranslationRow`(`.translationTask` → prepareTranslation) | 设置 › AI 润色与翻译、引导「翻译与 AI」 |
| 结束字幕(含询问保存) | `AppState.stopCaptions` | 字幕条 ⏹、⌃ 菜单 / 菜单栏、快捷键、设置 › 实时字幕、Passport、切换应用 |
| 字幕记录保存成文件 | `TranscriptSaver`(`CaptionTranscript.plainText`) | AppState.stopCaptions / prepareToQuit、字幕记录窗口 |

## 1. 听写(快捷键按住说话)

```
KeyboardShortcuts.onKeyDown(.dictate,默认 ⌥空格)
 → HotkeyManager.Actions.dictateDown
 → DictationController.pressDown(mode:)
 → PressInterpreter.down → .start
 → DictationController.start(mode:)
     ├─ ModelManager.isInstalled / EngineRegistry.engine(for:)
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
     → await sessionTask → ASRSession.finish → 文本
     → TranscriptText.normalize
     → postProcess:TextProcessor.polish | TranslationService.translateDictation
         (有 LLM 且方式允许 → TextProcessor.translate;否则 LanguageDetector → SystemTranslator)(失败退回原文)
     → TextInserter.insert
          → snapshot 剪贴板 → copy → KeySender.press(⌘V, KeyLayout) → 700 ms 后 restore
     → succeed(DictationResult) / fail(DictationFailure)(类型化结果,界面用 .title 显示)→ 1.2 s 后回到 idle
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
 ├─ 流式(火山引擎 / 百炼 / ElevenLabs):StreamingCloudSession(makeCodec)
 │    feed → inbox → run → AudioFormats.pcm16 → RealtimeCodec.audioMessage → CloudConnection.send
 │    CloudConnection.receive → RealtimeCodec.parse → .ready / .partial / .final / .completed / .failure
 │    finish → 补发尾包 + RealtimeCodec.finishMessages → 等 .completed(或结束后的定稿)→ 拼接定稿
 └─ OpenAI 兼容:SegmentedSession(OpenAITranscriptionDecoder)
      → VAD 分段 → 松开后整段 AudioFormats.wav → MultipartForm → POST /audio/transcriptions
出错:会话发出 TranscriptEvent.failure → DictationController.streamError(没有文字时 fail(.other))
 / SubtitleController.streamError(字幕条红字);字幕模式断线后指数退避自动重连,断线时的中间结果先定稿
```

## 2. 听写(Passport OK 键)

```
DeviceLink(USB/BLE)→ DeviceMessage.parse → RecentEventFilter → DeviceLink.lastKey / onKey
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
所有命令:HostCommand.encode → DeviceText.ascii → USB SerialPort.write | BLEClient.send
```

## 3a. Passport 模式与 OK 键

```
设备模式(长按上键循环 dict → tr → sub,听写进行中不切换)
 dict / tr:OK = 听写(按住说话 / 轻按免提),字幕在后台运行也不影响;空闲页 msg "LIVE" 显示 LIVE 标记
 sub:OK = 没有字幕时打开设备列表「CAPTIONS」选择应用 → Hooks.startCaptions;有字幕时 Hooks.stopCaptions(= AppState.stopCaptions)
       (Mac 上正显示模态框时不响应)
       上 / 下短按 = 字幕翻译开关(需已配置 AI,与 Mac 上一致)/ 收起展开字幕条(仅字幕运行时)
DeviceStateMapper.state:听写阶段优先 → 列表 → 字幕页(仅 sub 模式且字幕运行)→ 空闲页(+LIVE)
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
 → 列表模式:switcherPressBegan(上:移动;OK:前置应用并关闭)/ 长按下:关闭 / 下键短按松开:移动
 → 列表关闭后 OK 锁定 250 ms(防抖,避免误触听写)
固件侧:ADC 按键 20 ms 去抖 + 同键松开后 60 ms 内的再次按下忽略(ib_keys)
```

## 4. Passport 按键 → vibe coding 动作

```
DeviceBridge(见 3b 的手势结果)
 ├─ agentAck 归属 → AgentNotifier.dismiss(这次按压只用来关闭通知)
 ├─ 字幕模式:设置.subtitleTranslate.toggle | Hooks.toggleSubtitleBar → PillUIState.subtitleCollapsed
 └─ perform(KeyAction)
       → .pasteLast → DictationController.reinsertLast → TextInserter.insert
       → .nextMode  → DeviceBridge.cycleMode → sync
       → 其他       → KeySender.perform → KeySender.press / type
```

## 4b. Passport 切换应用(vibe coding)

```
长按 ▼(默认动作 KeyAction.appSwitcher,可在设置里改)
 → DeviceBridge.perform → openSwitcher
     → AppSwitcher.list(普通应用,按窗口前后顺序 = 最近使用;默认选中第二个,同 ⌘Tab)
     → sync:DeviceStateMapper.state → .list → DeviceLink.sendState(list) + sendSwitcher
     → DeviceLink.sendList → HostCommand.listTop(选中项居中的可见窗口)→ HostCommand.list
列表打开时按键:DeviceBridge.handleSwitcher
 ▲ / ▼ → 移动选中并重发 list;OK → AppSwitcher.activate → 关闭;长按 ▼ 或 15 秒无操作 → 关闭
AppSwitcher.activate(行为同 ⌘Tab / 点 Dock):取消隐藏 → AX 设为最前(失败退回 activate)
 → 抬起可见窗口 / 恢复最小化窗口 / 没有窗口时发送重新打开事件
```

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
          → .partial → CaptionFeed.partial(快速路径:有系统翻译或不翻译)
              → CaptionSegmenter.hypothesis(LocalAgreement-2:连续两次结果一致的词才确认,已确认文字只追加不改写)
              → SentenceSplitter.split(已确认文字,对增长稳定)→ 新确认的整句 → CaptionUnit
              → TranslationService.quickTranslate(系统翻译,几十毫秒)→ unit.translation
          → .final → SentenceSplitter.split(final: true)→ 每句一条 CaptionTranscript.Entry(完整记录)
              → CaptionFeed.final:快速路径 → CaptionSegmenter.final(用已给出部分的末尾词定位,只补没给出的句子;
                 多段分次定稿时超出部分留给下一段抵扣);只有 AI 时 → 按记录句子生成 unit 并关联
              → 开启翻译 → 每句 TranslationService.translateLine(前 3 句原文 + 译文作上下文):
                 ① LanguageDetector → TargetLanguage.resolved → SystemTranslator.translate → .draft
                 ② LLM:TextProcessor.translateSubtitle(带初稿)→ LLMClient.stream(SSE)→ 完整后 .final
                 ③ 只有系统翻译 → 初稿即定稿;都失败 → .failed
                 → CaptionTranscript.setTranslation(draft:)(记录窗口 / 保存文件用 AI 版)
                 → CaptionFeed.entryTranslation(同步到关联的 unit,还没显示的句子用上更好的译文)
          → 打开翻译 / 换目标语言(字幕条翻译菜单或设置)→ SubtitleController.translateLatest(清空并重译最新一句)
 → CaptionFeed.advance(每次新内容 + 每 0.5 秒)→ RollingCaptions.update(同传类应用的两行滚动字幕):
     原文行 = 已确认句子 + 正在说的部分(跟着语音实时走,未确认部分略暗);
     译文行 = 按句子顺序接上的译文(接上后锁定不改;等译文超时 / 失败的句子跳过),通常比原文慢一两句;
     起点固定、只在末尾增长(换行稳定),累计超过 420 字符才按整句移动起点
 → SubtitleSurface:原文(小)在上、译文(大)在下,各一个固定 2 行高的框,底部对齐、旧行整行滚出,左对齐;
     有字幕后宽度固定(宽度变化会让换行重排);标题栏只在悬停时出现(先加宽再淡入、先淡出再收窄);
     字幕文字 allowsHitTesting(false),不挡标题栏按钮
 → SubtitleSurface.translationMenu(「译」标签):开关译文、选择目标语言 → AppSettings.subtitleTranslate / subtitleTarget
 → PillView:dictation 空闲且字幕运行、没收起时显示 SubtitleSurface(与胶囊同一个 glassEffectID,变形过渡)
结束(所有入口):AppState.stopCaptions
 → SubtitleController.stop(未定稿的半句记入记录)→ AppAudioTap.stop → ASRSession.cancel
 → 有未保存内容且 askToSaveCaptions → 下一轮事件循环 TranscriptSaver.askToSave(NSAlert:保存… / 不保存 / 不再询问)
     → 保存… → NSSavePanel(用户选位置)→ CaptionTranscript.plainText → 写 UTF-8 文本 → SubtitleController.markTranscriptSaved(id)
退出 app:AppDelegate.applicationShouldTerminate → AppState.prepareToQuit(同样询问,同步)
```

字幕记录(app 不保存任何历史,记录只在内存里,下次开始字幕或退出后清除):

```
字幕条 📄 / ⌃ 菜单与菜单栏「字幕记录…」/ 设置 › 实时字幕「查看」→ WindowManager.showTranscript
 → TranscriptView(只读 SubtitleController.transcript / partial,跟随最新自动滚动)
     「拷贝全部」→ CaptionTranscript.plainText → NSPasteboard
     「保存…」→ WindowManager.saveTranscriptFromWindow → TranscriptSaver.save(in: window)(表单形式的保存面板)
 正文 TranscriptTextView(NSTextView,只读可跨行选择;只重排变化的尾部,译文异步到达时不重建整篇)
 「总结」标签页 → SummaryView(出现 / 消失 → TranscriptSummarizer.setTabVisible)
     WindowManager.showTranscript / windowWillClose / 最小化 → setWindowVisible
     isActive = 窗口开着 && 停在总结页 && AppSettings.summaryEnabled;不满足 → 暂停定时检查并取消进行中的请求
     定时检查(5 秒)→ 距上次 ≥ summaryInterval 分钟且新内容 ≥ 4 句(字幕结束后剩余内容也总结)→ summarize
       → AppSettings.summaryLLMConfig(接口和 Key 只来自 设置 › AI 的服务;模型可在总结页从该接口的模型列表另选,默认跟随)
       → Prompts.summarize(用户主语言,2–5 条要点)+ summaryUser(新内容 + 上一段总结作上下文)
       → LLMClient.stream(边生成边显示)→ sections;「立即总结」→ summarizeNow
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
| 字幕运行且展开 | 字幕条 | 「译」标签菜单:开关译文、目标语言;悬停:字号、锁定、📄 字幕记录、🎤 听写、⌄ 收起、⏹ 结束 |
| 悬停,没有字幕 | 工具条 | 🎤 听写;◉ 弹出应用列表(`MenuBuilder.captionAppsMenu`)选择后开始;⌃ 菜单 |
| 悬停,字幕已收起 | 工具条 | ◉ 展开字幕条;结束、字幕记录在 ⌃ 菜单 |
| 不悬停 | Agent 通知 / 细胶囊 | 字幕在后台运行时细胶囊带红点 |

开始字幕的所有入口(胶囊 ◉、开关字幕快捷键、菜单栏、设置页、Passport 字幕模式)都先选择应用,然后调用 `AppState.startCaptions`(展开字幕条 → `SubtitleController.start`);不沿用上次的应用。
正在为某个应用生成字幕时选择另一个应用:`AppState.startCaptions` 先走 `stopCaptions`(询问保存上一场),再开始新的;
选的是正在转录的同一个应用时只展开字幕条,不重新开始(不清空记录)。

启动规则(`SubtitleController.start`):每次 start / stop 递增 `generation`,启动任务(加载模型 / 连接云端)完成时代数变了就丢弃会话,
不会出现两场同时运行;音频采集启动失败时关闭已建立的识别会话。启动失败(模型不可用、没有系统音频权限)时 `needsSurface` 为真,
字幕条显示原因(`ModelManager.unavailableMessage` 区分"未下载"和"未配置"),只有 ✕ 关闭,点了走 `stopCaptions`(不询问保存)。
设置里隐藏了状态条时,字幕运行 / 失败 / 选择字幕应用期间仍强制显示(`PillPanelController.show(force:)`),结束后恢复隐藏。
听写进行中才开始的字幕:会话进入 running 时按 `dictation.phase` 立即暂停解码。
同时只会有一个"保存字幕吗?"询问框(`TranscriptSaver.isAsking`);询问框显示期间 Passport 字幕模式的 OK 不响应。
结束字幕的所有入口都调用 `AppState.stopCaptions`。字幕条锁定(穿透)后,收起 / 展开 / 结束都可以在菜单栏和 ⌃ 菜单里操作。

空闲胶囊:`IdleCapsule` 呼吸(Core Animation 循环,尊重"减少动态效果");`PillView.task(id: activityKey)` 计时,
30 秒无活动 → dimmed(内芯降低亮度、玻璃换 clear 样式),任何状态 / 悬停变化立即恢复。


```
PillPanelController.startMouseTracking → updateHover(热区来自 PillView.reportHotRect)
 → PillUIState.isHovering → PillView.updateExpanded(延迟收起)
 → PillView.pill:按 DictationController.phase 加字幕和 Agent 状态选择形态
点击 → PillActions(AppState 注入)→ DictationController.toggle / SubtitleController / MenuBuilder.build → popUp
拖动 → DragGesture → PillWindowActions.dragChanged/dragEnded → PillPanelController 移动窗口并保存偏移
```

## 7. Agent 通知(vibe coding)

```
Claude Code hook:open -g 'inputbetter://agent?event=…'
 → AppDelegate.application(_:open:) → AppState.handle(url:)
 → AgentNotifier.handle(url:) → post
     ├─ current → PillView.agentPill(胶囊或字幕条上方)
     └─ onNotice → DeviceBridge → DeviceLink.sendAgent → 设备通知层与提示音
一键配置:VibePane.AgentHookRow → AgentHookInstaller.install(.claudeCode | .codex)
 → 读取并备份 ~/.claude/settings.json | ~/.codex/hooks.json → 合并同一格式的 hooks(去重)→ 写回
   Claude Code:Stop / Notification / UserPromptSubmit;Codex:Stop / PermissionRequest / UserPromptSubmit
   (Codex 需在 CLI 里 /hooks 信任一次;不改动 Codex 的 notify 设置)
```

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
         其他服务没有列表接口 → CloudProvider.knownModels(官方文档列出的实时识别模型 / 资源 ID))
     → 「测试连接」CloudASREngine.test → 1.5 秒近静音 → 有 .failure 则显示原因
     → 「保存」CloudASRStore.update → CredentialStore.set("cloud.<provider>.apiKey") + UserDefaults
 → ModelManager.state(cloud-…) == .installed(配置齐全即"可用")→ 可选为听写模型 / 字幕模型
听写和字幕各自选模型:AppSettings.dictationModelID / subtitleModelID(字幕选项里列出所有可用模型,含云端)
密钥:~/Library/Application Support/InputBetter/credentials.json(0600,仅当前用户可读);
旧版本存在钥匙串里的 LLM Key 在启动时静默迁移一次(不弹授权框),之后删除钥匙串条目
```

翻译方式(`TranslationEngine`,默认 `hybrid`):hybrid = 系统翻译初稿 + AI 润色替换;system = 仅系统翻译;llm = 仅 AI。
`TranslationService.isAvailable`(系统语言包已下载 或 配置了 AI,按方式判断)决定字幕条「译」菜单、设置开关、菜单栏、Passport 上键能否打开翻译。
语言包:`TranslationService.refreshSystemStatus`(启动、目标语言变化、app 重新激活时)→ `SystemTranslator.status`;
下载:`SystemTranslationRow`「下载」→ `.translationTask` → `prepareTranslation()`(系统弹窗确认)→ `systemDownloadFinished`;
或「在系统设置中管理」→ 系统设置 › 通用 › 语言与地区 › 翻译语言。字幕条「译」菜单在不可用时提供「打开翻译设置…」→ `WindowManager.showSettings(.ai)`。

翻译目标语言(`TargetLanguage`,听写和字幕各一个,默认 `auto`):
`auto` → `Prompts.target` → `TargetLanguage.autoPair`(系统首选语言 P + 另一种语言:英语,P 是英语时取第二首选语言或简体中文)
→ 提示词"译成 P;原文已经是 P 就译成另一种语言"。

## 8b. LLM 配置

```
设置 › AI / 引导 AI 页 → LLMConfigForm
 → 服务商预设 → AppSettings.llmBaseURL / llmModel
 → 地址或 Key 变化 → .task(id:) 停顿 0.6 秒 → OpenAICompatibleAPI.listModels(GET /models)
     → ModelPickerField 下拉选择(当前值不在列表里也保留显示;"手动输入…"切换成文本框;失败时显示原因并可手动输入)
 → 「测试连接」LLMClient.complete(一句 ping)
```

## 9. 一键刷固件 / 更新固件

```
PassportSetupView「刷入固件」→ PassportSetupModel.flashFirmware
 → FirmwareFlasher.flash(port:) → run
     → DeviceLink.suspendUSB(让出串口)
     → FirmwareBundle.load / validate(镜像都在 cardid 0x356000 之前)
     → EsptoolRunner.run(read-mac)→ EsptoolRunner.mac
     → ensureBackup:已有备份则跳过,否则 EsptoolRunner.run(read-flash 8 MB)→ 校验大小
     → EsptoolRunner.run(write-flash 三个镜像)→ EsptoolRunner.progress → phase
     → DeviceLink.resumeUSB → 重新握手 → PassportSetupModel.stage == .connected
设备识别:DeviceLink.handleHello(固件名不符)/ 握手超时 → handshakeFailed → foreignDevice → stage .needsFirmware
是否需要更新:DeviceLink.firmwareBuild(hello 的 build)≠ FirmwareBundle.build(manifest,取自 app.bin 0xB0)
 → PassportSetupModel.firmwareUpdateAvailable → 「更新固件」;相同则显示「重新刷入」(都用 DeviceLink.usbPortPath)
刷写期间 PassportSetupModel.stage == .flashing(USB 暂停,不按连接状态判断)
```

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

## 11. 设置联动

```
AppSettings(didSet 写 UserDefaults;API Key 写 CredentialStore)
 → AppState.observeSettings(observeChanges)
     showPill → PillPanelController.show/hide
     deviceBluetooth → AppState.updateBluetooth → DeviceLink.bluetoothEnabled
     dictationModelID → EngineRegistry.unloadAll / preload
     language → ModelManager.languageChanged
     subtitles.status → PillUIState.subtitleCollapsed 复位 / PillPanelController.show
```
