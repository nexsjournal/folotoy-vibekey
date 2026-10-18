import AppKit
import SwiftUI

/// 组合根:创建所有模块、注入依赖、把它们连起来。其他类型都不直接创建彼此。
@MainActor @Observable
final class AppState {
    let settings: AppSettings
    let language = LanguageState()
    let permissions: Permissions
    let inputDevices: InputDevices
    let models: ModelManager
    /// 云端识别配置(API Key 存本机凭据文件)。
    let cloudASR: CloudASRStore
    let engines: EngineRegistry
    let processor: TextProcessor
    /// 在线翻译服务的凭据(密钥存本机凭据文件)。
    let translationProviders: MachineTranslationStore
    /// 翻译入口(系统翻译 / 在线服务 / AI,字幕、字幕记录和听写共用)。
    let translation: TranslationService
    /// LLM 服务的模型列表(翻译方式、总结里快速选模型)。
    let llmModels: LLMModelCatalog
    let deviceLink: DeviceLink
    let dictation: DictationController
    let subtitles: SubtitleController
    /// 字幕记录的分段总结(字幕记录窗口「总结」页)。
    let summarizer: TranscriptSummarizer
    /// 字幕记录窗口里的批量翻译 / AI 润色。
    let transcriptTranslator: TranscriptTranslator
    let agent: AgentNotifier
    let firmware: FirmwareFlasher
    let passportSetup: PassportSetupModel
    @ObservationIgnored let hotkeys: HotkeyManager
    @ObservationIgnored private(set) var windows: WindowManager!
    @ObservationIgnored private var pill: PillPanelController!
    @ObservationIgnored private var bridge: DeviceBridge!
    @ObservationIgnored private var menus: MenuBuilder!
    @ObservationIgnored private var statusMenu: StatusMenuController?

    /// Passport 固件清单地址:正式版固定用官网;调试构建可用 IB_FIRMWARE_MANIFEST 指向本机测试服务器。
    private static var firmwareManifestURL: URL {
        #if DEBUG
        if let url = DebugHooks.firmwareManifestURL { return url }
        #endif
        return FirmwareDownloader.officialManifestURL
    }

    init() {
        // 本机凭据文件只有这一个实例,注入给所有需要 API Key 的模块(各自缓存会互相覆盖)。
        let credentials = CredentialStore()
        let settings = AppSettings(credentials: credentials)
        self.settings = settings
        permissions = Permissions()
        inputDevices = InputDevices()
        cloudASR = CloudASRStore(credentials: credentials)
        models = ModelManager(settings: settings, cloud: cloudASR)
        engines = EngineRegistry(cloud: cloudASR)
        processor = TextProcessor(settings: settings)
        translationProviders = MachineTranslationStore(credentials: credentials)
        translation = TranslationService(settings: settings, processor: processor, providers: translationProviders)
        llmModels = LLMModelCatalog(settings: settings)
        deviceLink = DeviceLink()
        agent = AgentNotifier()
        firmware = FirmwareFlasher(link: deviceLink, downloader: FirmwareDownloader(manifestURL: Self.firmwareManifestURL))
        passportSetup = PassportSetupModel(link: deviceLink, flasher: firmware, settings: settings)
        hotkeys = HotkeyManager()
        subtitles = SubtitleController(settings: settings, models: models, engines: engines, translation: translation)
        summarizer = TranscriptSummarizer(settings: settings, subtitles: subtitles)
        transcriptTranslator = TranscriptTranslator(settings: settings, subtitles: subtitles, translation: translation)

        // 音源工厂:选了 Passport 且已连接时用设备麦克风,否则用系统输入设备。
        let link = deviceLink
        let inputDevices = inputDevices
        dictation = DictationController(
            settings: settings, engines: InstalledDictationEngines(models: models, engines: engines),
            postProcessor: DictationPostProcessor(settings: settings, processor: processor, translation: translation),
            inserter: TextInserter(), sounds: SoundEffects(settings: settings),
            makeSource: {
                if settings.micID == AppSettings.passportMicID, link.connection != .disconnected {
                    return PassportMicSource(link: link)
                }
                let uid = settings.micID
                let exists = !uid.isEmpty && uid != AppSettings.passportMicID && inputDevices.device(uid: uid) != nil
                return MicSource(deviceUID: exists ? uid : nil)
            })
    }

    /// 启动:创建窗口与菜单、挂快捷键、连接设备、预加载模型。
    func launch() {
        windows = WindowManager(app: self)
        menus = MenuBuilder(app: self)
        pill = PillPanelController(content: { [unowned self] ui, window in
            AnyView(LocalizedRoot(language: language) { PillView(
                dictation: dictation, subtitles: subtitles, agent: agent, translation: translation, catalog: llmModels, ui: ui,
                settings: settings, permissions: permissions,
                hotkeyHint: { [unowned self] in hotkeys.dictateDescription },
                actions: pillActions, window: window) })
        }, settings: settings)

        bridge = DeviceBridge(link: deviceLink, dictation: dictation, subtitles: subtitles, agent: agent,
                              settings: settings, hooks: .init(toggleSubtitleBar: { [unowned self] in
                                  setCaptionsCollapsed(!captionsCollapsed)
                              }, startCaptions: { [unowned self] app in startCaptions(app) },
                              stopCaptions: { [unowned self] in stopCaptions(fromDevice: true) },
                              canTranslate: { [unowned self] in translation.isAvailable }))
        bridge.start()
        // 引导走到 Passport 一步之前不打开蓝牙,避免一启动就弹出蓝牙权限框。
        updateBluetooth()
        deviceLink.start()

        hotkeys.start(.init(
            dictateDown: { [unowned self] in dictation.pressDown(mode: .dictate) },
            dictateUp: { [unowned self] in dictation.pressUp() },
            translateDown: { [unowned self] in dictation.pressDown(mode: .translate) },
            translateUp: { [unowned self] in dictation.pressUp() },
            toggleSubtitles: { [unowned self] in toggleCaptionsFromShortcut() },
            resetPillPosition: { [unowned self] in resetPillPosition() }))

        installStatusItem()
        observeSettings()
        Task { await translation.refreshSystemStatus() }
        llmModels.loadIfNeeded()

        #if DEBUG
        // 调试用:IB_SETTINGS_PANE 打开设置窗口,IB_ONBOARDING_STEP 打开引导。
        let env = ProcessInfo.processInfo.environment
        if env["IB_SETTINGS_PANE"] != nil { windows.showSettings() }
        if env["IB_ONBOARDING_STEP"] != nil { windows.showOnboarding(); return }
        DebugHooks.run(app: self)
        if env["IB_SHOW_PILL"] != nil || env["IB_TRANSCRIBE_FILE"] != nil { return }
        #endif
        if settings.onboardingDone {
            pill.show()
            engines.preload(settings.dictationModelID)
        } else {
            windows.showOnboarding()
        }
    }

    /// onboarding 完成后调用。
    func finishOnboarding() {
        settings.onboardingDone = true
        updateBluetooth()
        pill.show()
        engines.preload(settings.dictationModelID)
    }

    /// 显示底部状态条(引导的"试一试"一步也会调用)。
    func showPill() {
        pill.show()
    }

    func handle(url: URL) {
        agent.handle(url: url)
    }

    /// 退出前:字幕还在进行时确认一次(记录只在内存里,退出后就没了)。返回 false 表示用户取消退出。
    func prepareToQuit() -> Bool {
        guard subtitles.isRunning else { return true }
        return CaptionsConfirmation.confirmQuit(appName: subtitles.appName)
    }

    func shutdown() {
        subtitles.stop()
        dictation.cancel()
        deviceLink.stop()
    }

    // MARK: - 动作

    private var pillActions: PillActions {
        PillActions(
            toggleDictation: { [unowned self] in dictation.toggle() },
            startCaptions: { [unowned self] point in pill.popUp(menus.captionAppsMenu(), at: point) },
            expandCaptions: { [unowned self] in setCaptionsCollapsed(false) },
            collapseCaptions: { [unowned self] in setCaptionsCollapsed(true) },
            stopCaptions: { [unowned self] in stopCaptions() },
            showTranscript: { [unowned self] in windows.showTranscript() },
            // 字幕条上的「翻译设置…」:字幕的翻译方式在 设置 › 实时字幕 里选。
            openTranslationSettings: { [unowned self] in windows.showSettings(.subtitles) },
            configureTranslationProvider: { [unowned self] provider in
                windows.showSettings(.translation, configure: provider, useFor: .subtitles)
            },
            openSystemTranslation: { [unowned self] in windows.showSettings(.translation, systemTranslation: true) },
            openLLMSettings: { [unowned self] in windows.showSettings(.ai) },
            openDictationSettings: { [unowned self] in windows.showSettings(.dictation) },
            showMenu: { [unowned self] point in pill.popUp(menus.build(), at: point) },
            cancel: { [unowned self] in dictation.cancel() },
            confirm: { [unowned self] in dictation.stop() },
            dismissAgent: { [unowned self] in agent.dismiss() })
    }

    /// 字幕条是否收起(菜单、Passport、字幕条按钮共用)。
    var captionsCollapsed: Bool { pill.ui.subtitleCollapsed }

    func setCaptionsCollapsed(_ collapsed: Bool) {
        pill.ui.subtitleCollapsed = collapsed
    }

    /// 开始为某个应用生成字幕(所有入口都走这里):字幕条默认展开。
    /// 正在为别的应用生成字幕时:开始新的一场会替换上一场的记录。记录里还有没保存的内容就先确认
    /// (可以选择先打开字幕记录去保存);没有要保存的内容就直接切换。
    func startCaptions(_ app: AudioApp) {
        pill.ui.subtitleCollapsed = false
        // 已经在为这个应用生成字幕:只展开字幕条,不重新开始(否则会清掉当前记录)。
        if subtitles.isRunning, subtitles.appBundleID == app.bundleID { return }
        guard subtitles.isRunning, subtitles.transcript.hasUnsavedEntries else {
            subtitles.start(app: app)  // start 内部会先结束正在进行的一场
            return
        }
        let oldApp = subtitles.appName, sentences = subtitles.transcript.entries.count
        let session = subtitles.transcript.id
        // 放到下一轮事件循环再弹框(避免在菜单 / 按钮的事件处理中弹出模态框);确认后再检查一次还是同一场字幕。
        Task { @MainActor [unowned self] in
            guard subtitles.isRunning, subtitles.transcript.id == session else { return }
            switch CaptionsConfirmation.confirmSwitch(from: oldApp, to: app.name, sentences: sentences) {
            case .switchApp:
                guard subtitles.isRunning, subtitles.transcript.id == session else { return }
                subtitles.start(app: app)
            case .openTranscript:
                windows.showTranscript(tab: .captions, activate: true)
            case .cancel:
                break
            }
        }
    }

    /// 结束字幕(所有入口都走这里:字幕条、菜单、快捷键、设置、Passport)。
    /// 只确认"是否结束"(设置里可关);结束后如果字幕记录窗口没在显示,就打开它——保存、总结由用户在窗口里处理。
    /// - Parameter fromDevice: Passport 上结束时为 true:不弹确认框(设备上没法回答),
    ///   打开字幕记录窗口但不激活 InputBetter(否则设备上的回车 / Esc 会发到 InputBetter 而不是用户正在用的应用)。
    /// 启动失败时(字幕条显示原因)调用则只是关闭字幕条。
    func stopCaptions(fromDevice: Bool = false) {
        guard subtitles.needsSurface else { return }
        guard subtitles.isRunning else {
            subtitles.stop()
            return
        }
        let finish: @MainActor @Sendable () -> Void = { [unowned self] in
            subtitles.stop()
            if !subtitles.transcript.isEmpty, !windows.isTranscriptVisible {
                windows.showTranscript(tab: .captions, activate: !fromDevice)
            }
        }
        fromDevice ? finish() : confirmThen(finish)
    }

    /// 需要时先确认结束当前字幕再执行。确认框放到下一轮事件循环,避免在菜单 / 按钮的事件处理过程中弹出模态框;
    /// 确认后再检查一次字幕还在运行(期间可能已经被别的入口结束)。
    private func confirmThen(_ action: @escaping @MainActor @Sendable () -> Void) {
        guard settings.confirmStopCaptions else {
            action()
            return
        }
        let appName = subtitles.appName, sentences = subtitles.transcript.entries.count
        Task { @MainActor [unowned self] in
            guard subtitles.isRunning,
                  CaptionsConfirmation.confirmStop(appName: appName, sentences: sentences, settings: settings),
                  subtitles.isRunning else { return }
            action()
        }
    }

    /// 开关字幕快捷键:运行中则结束;否则在状态条上方弹出应用列表让用户选择(不沿用上一次的应用)。
    func toggleCaptionsFromShortcut() {
        if subtitles.isRunning {
            stopCaptions()
        } else {
            pill.show(force: true)
            pill.popUpAtPill(menus.captionAppsMenu())  // 同步:菜单关闭后才返回
            // 没选应用就关掉了菜单,且用户设置了隐藏状态条:恢复隐藏。
            if !subtitles.needsSurface, !settings.showPill { pill.hide() }
        }
    }

    // MARK: - 菜单栏

    private func installStatusItem() {
        statusMenu = StatusMenuController { [unowned self] in menus.build() }
    }

    // MARK: - 设置联动

    private func observeSettings() {
        observeChanges({ [unowned self] in _ = settings.showPill }) { [unowned self] in
            settings.showPill ? pill.show() : pill.hide()
        }
        observeChanges({ [unowned self] in _ = settings.deviceBluetooth }) { [unowned self] in
            updateBluetooth()
        }
        // 换听写或字幕模型:卸载不再使用的引擎(释放内存),预加载听写模型。
        observeChanges({ [unowned self] in _ = (settings.dictationModelID, settings.subtitleModelID) }) { [unowned self] in
            engines.unloadAll(except: [settings.dictationModelID, settings.effectiveSubtitleModelID])
            engines.preload(settings.dictationModelID)
        }
        observeChanges({ [unowned self] in _ = settings.language }) { [unowned self] in models.languageChanged() }
        // 换目标语言或翻译方式:翻译中的话重新翻译最新一句(开关本身由 SubtitleController 处理)。
        observeChanges({ [unowned self] in _ = (settings.subtitleTarget, settings.subtitleTranslationMethod) }) { [unowned self] in
            subtitles.translationConfigChanged()
        }
        observeChanges({ [unowned self] in _ = subtitles.status }) { [unowned self] in
            // 字幕停止后复位"收起"状态。
            if !subtitles.isRunning { pill.ui.subtitleCollapsed = false }
            // 字幕运行或显示启动失败原因时,即使设置了隐藏状态条也要显示(字幕条就是状态条);结束后恢复隐藏。
            if subtitles.needsSurface { pill.show(force: true) } else if !settings.showPill { pill.hide() }
            // 听写进行中才开始的字幕:新会话同样要暂停解码,保持听写优先。
            if subtitles.status == .running { subtitles.setDecodingPaused(dictation.phase.isBusy) }
        }
        // 听写优先:听写进行中暂停字幕解码(音频照常缓存),结束后字幕自动补上。
        observeChanges({ [unowned self] in _ = dictation.phase }) { [unowned self] in
            subtitles.setDecodingPaused(dictation.phase.isBusy)
        }
    }

    /// 引导进入 Passport 一步后允许蓝牙(用户在这里第一次看到蓝牙相关说明)。
    func unlockBluetooth() {
        bluetoothUnlocked = true
        updateBluetooth()
    }

    @ObservationIgnored private var bluetoothUnlocked = false

    private func updateBluetooth() {
        deviceLink.bluetoothEnabled = settings.deviceBluetooth && (settings.onboardingDone || bluetoothUnlocked)
    }

    /// 状态条回到屏幕底部中央。
    func resetPillPosition() {
        pill.resetPosition()
    }
}
