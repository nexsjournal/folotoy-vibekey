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
    /// 翻译入口(系统翻译 + LLM,字幕和听写共用)。
    let translation: TranslationService
    let deviceLink: DeviceLink
    let dictation: DictationController
    let subtitles: SubtitleController
    let agent: AgentNotifier
    let firmware: FirmwareFlasher
    let passportSetup: PassportSetupModel
    @ObservationIgnored let hotkeys: HotkeyManager
    @ObservationIgnored private(set) var windows: WindowManager!
    @ObservationIgnored private var pill: PillPanelController!
    @ObservationIgnored private var bridge: DeviceBridge!
    @ObservationIgnored private var menus: MenuBuilder!
    @ObservationIgnored private var statusItem: NSStatusItem?

    init() {
        let settings = AppSettings()
        self.settings = settings
        permissions = Permissions()
        inputDevices = InputDevices()
        cloudASR = CloudASRStore()
        models = ModelManager(settings: settings, cloud: cloudASR)
        engines = EngineRegistry(cloud: cloudASR)
        processor = TextProcessor(settings: settings)
        translation = TranslationService(settings: settings, processor: processor)
        deviceLink = DeviceLink()
        agent = AgentNotifier()
        firmware = FirmwareFlasher(link: deviceLink)
        passportSetup = PassportSetupModel(link: deviceLink, flasher: firmware, settings: settings)
        hotkeys = HotkeyManager()
        subtitles = SubtitleController(settings: settings, models: models, engines: engines, translation: translation)

        // 音源工厂:选了 Passport 且已连接时用设备麦克风,否则用系统输入设备。
        let link = deviceLink
        let inputDevices = inputDevices
        dictation = DictationController(
            settings: settings, models: models, engines: engines, processor: processor, translation: translation,
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
                dictation: dictation, subtitles: subtitles, agent: agent, translation: translation, ui: ui,
                settings: settings, permissions: permissions,
                hotkeyHint: { [unowned self] in hotkeys.dictateDescription },
                actions: pillActions, window: window) })
        }, settings: settings)

        bridge = DeviceBridge(link: deviceLink, dictation: dictation, subtitles: subtitles, agent: agent,
                              settings: settings, hooks: .init(toggleSubtitleBar: { [unowned self] in
                                  setCaptionsCollapsed(!captionsCollapsed)
                              }, startCaptions: { [unowned self] app in startCaptions(app) },
                              stopCaptions: { [unowned self] in stopCaptions() },
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
            toggleSubtitles: { [unowned self] in toggleCaptionsFromShortcut() }))

        installStatusItem()
        observeSettings()
        Task { await translation.refreshSystemStatus() }

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

    /// 退出前:字幕还有没保存的记录时先询问(和结束字幕的询问相同),然后再退出。
    func prepareToQuit() {
        guard subtitles.isRunning else { return }
        subtitles.stop()
        let record = subtitles.transcript
        guard settings.askToSaveCaptions, record.hasUnsavedEntries else { return }
        if TranscriptSaver.askToSave(record, settings: settings) { subtitles.markTranscriptSaved(record) }
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
            openTranslationSettings: { [unowned self] in windows.showSettings(.ai) },
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
    /// 正在为别的应用生成字幕时,先按正常流程结束上一场(会询问是否保存它的记录)。
    func startCaptions(_ app: AudioApp) {
        pill.ui.subtitleCollapsed = false
        // 已经在为这个应用生成字幕:只展开字幕条,不重新开始(否则会清掉当前记录)。
        if subtitles.isRunning, subtitles.appBundleID == app.bundleID { return }
        if subtitles.isRunning { stopCaptions() }
        subtitles.start(app: app)
    }

    /// 结束字幕(所有入口都走这里:字幕条、菜单、快捷键、设置、Passport)。
    /// 有未保存的记录且设置允许时,询问是否保存成文件。询问放到下一轮事件循环,
    /// 避免在菜单 / 按钮的事件处理过程中弹出模态框;记录按值捕获,之后开始新字幕也不影响。
    /// 启动失败时(字幕条显示原因)调用则只是关闭字幕条。
    func stopCaptions() {
        guard subtitles.needsSurface else { return }
        let wasRunning = subtitles.isRunning
        subtitles.stop()
        let record = subtitles.transcript
        guard wasRunning, settings.askToSaveCaptions, record.hasUnsavedEntries else { return }
        Task { @MainActor [unowned self] in
            if TranscriptSaver.askToSave(record, settings: settings) { subtitles.markTranscriptSaved(record) }
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "InputBetter")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
    }

    @objc private func statusItemClicked() {
        guard let item = statusItem else { return }
        item.menu = menus.build()
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: - 设置联动

    private func observeSettings() {
        observeChanges({ [unowned self] in _ = settings.showPill }) { [unowned self] in
            settings.showPill ? pill.show() : pill.hide()
        }
        observeChanges({ [unowned self] in _ = settings.deviceBluetooth }) { [unowned self] in
            updateBluetooth()
        }
        observeChanges({ [unowned self] in _ = settings.dictationModelID }) { [unowned self] in
            engines.unloadAll(except: [settings.dictationModelID, settings.effectiveSubtitleModelID])
            engines.preload(settings.dictationModelID)
        }
        observeChanges({ [unowned self] in _ = settings.language }) { [unowned self] in models.languageChanged() }
        // 打开翻译或换目标语言:重新翻译最新一句。
        observeChanges({ [unowned self] in _ = (settings.subtitleTranslate, settings.subtitleTarget) }) { [unowned self] in
            subtitles.translateLatest()
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
