import AppKit

/// 把 Passport 设备接到听写、字幕和 vibe coding 动作上:
/// - 设备按键 → 手势(KeyPressTracker)→ 听写 / 字幕 / 快捷键 / 列表动作;
/// - app 状态 → 设备界面(state / level / keys / config / list),Agent 通知 → 设备通知层。
/// 用 16 Hz 定时器比较差异后下发,不需要各控制器主动通知,保持解耦。
///
/// 交互规则(docs/architecture.md「Passport 按键」):
/// - 显示与按键分开:字幕在运行时设备显示字幕页(不管哪个模式);按键含义由设备模式决定。
/// - OK:听写进行中始终交给听写(按住说话 / 免提停止);否则听写 / 翻译模式是说话,
///   字幕模式下没有字幕时打开"选择应用"列表、有字幕时结束字幕。
/// - 列表页(切换应用 / 选择字幕应用)打开时,按键只用于列表。
@MainActor
final class DeviceBridge {
    /// 需要 AppState 提供的动作。
    struct Hooks {
        /// 收起 / 展开 Mac 上的字幕条。
        var toggleSubtitleBar: () -> Void
        /// 开始为某个应用生成字幕(与 Mac 上的入口走同一个函数)。
        var startCaptions: (AudioApp) -> Void
        /// 结束字幕(与 Mac 上的入口走同一个函数,会询问是否保存记录)。
        var stopCaptions: () -> Void
        /// 翻译是否可用(系统翻译语言包或 AI),与 Mac 上的翻译开关一致。
        var canTranslate: () -> Bool
    }

    /// 设备上的列表页:切换应用,或为字幕选择应用。
    private struct ListSession {
        enum Purpose {
            case switchApp([SwitchableApp])
            case pickCaptionApp([AudioApp])
        }

        let purpose: Purpose
        var selected: Int
        var touched = Date()

        var title: String {
            switch purpose {
            case .switchApp: "SWITCH APP"
            case .pickCaptionApp: "CAPTIONS"
            }
        }

        var names: [String] {
            switch purpose {
            case .switchApp(let apps): apps.map(\.name)
            case .pickCaptionApp(let apps): apps.map { $0.isPlaying ? "\($0.name) *" : $0.name }
            }
        }

        var count: Int { names.count }
    }

    /// 设备上当前选择的模式(长按上键切换)。
    private(set) var mode: DeviceMode = .dict

    private let link: DeviceLink
    private let dictation: DictationController
    private let subtitles: SubtitleController
    private let agent: AgentNotifier
    private let settings: AppSettings
    private let hooks: Hooks
    private var timer: Timer?
    private var lastState: DeviceStateMapper.State?
    private var lastConfig: DeviceConfig?
    /// 正在显示的列表(nil 表示没打开)。
    private var list: ListSession?
    /// 列表无操作多久自动关闭。
    private let listTimeout: TimeInterval = 15
    /// 按键手势状态(按压归属、长按、防抖)。
    private var presses = KeyPressTracker()
    /// 列表关闭后忽略 OK 新按下的时长(防抖,避免误触听写)。
    private let okLockoutAfterList: TimeInterval = 0.25
    /// 这次 OK 按下交给了听写:松开时要发 pressUp(断线 / 切换链路时也要补发,否则按住说话收不了尾)。
    private var okDrivesDictation = false
    /// 设备上的临时错误提示(如没有可选的应用),到期前代替正常状态显示,时长与固件的错误页一致。
    private var deviceError: (msg: String, until: Date)?

    init(link: DeviceLink, dictation: DictationController, subtitles: SubtitleController,
         agent: AgentNotifier, settings: AppSettings, hooks: Hooks) {
        self.link = link
        self.dictation = dictation
        self.subtitles = subtitles
        self.agent = agent
        self.settings = settings
        self.hooks = hooks
    }

    func start() {
        link.onKey = { [weak self] key, event, ack in self?.handle(key, event, ack: ack) }
        link.onConnectionChange = { [weak self] connection in
            self?.connectionChanged(connection)
        }
        agent.onNotice = { [weak self] notice in
            guard let self else { return }
            let event: DeviceAgentEvent = switch notice.event {
            case .done: .done
            case .input: .input
            case .clear: .clear
            }
            link.sendAgent(event, msg: notice.source)
        }
        let timer = Timer(timeInterval: 1.0 / 16, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        // 加到 common 模式:菜单打开、模态提示框(如"保存字幕吗?")显示时设备状态也继续同步。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 连接变化(断开、重连、USB / 蓝牙切换):
    /// - 正按着 OK 说话:松开事件可能丢了,补一次 pressUp,免得按住说话停不下来;
    /// - 用 Passport 麦克风录音时设备断开:结束这次录音(已说的内容照常识别输入);
    /// - 强制重发全部状态,清掉未完成的按压和列表;还没处理的 Agent 提醒重新发给设备。
    private func connectionChanged(_ connection: DeviceLink.Connection) {
        if okDrivesDictation {
            okDrivesDictation = false
            dictation.pressUp()
        }
        let recording = dictation.phase == .recording || dictation.phase == .starting
        if connection == .disconnected, settings.micID == AppSettings.passportMicID, recording {
            dictation.stop()
        }
        presses.reset()
        list = nil
        lastState = nil
        lastConfig = nil
        sync()
        if connection != .disconnected, let notice = agent.current {
            agent.onNotice?(notice)
        }
    }

    // MARK: - 按键

    /// 原始按键 → 手势 → 动作。手势规则见 `KeyPressTracker`(按压归属、松开判定短按、防抖锁定)。
    private func handle(_ key: DeviceKey, _ event: DeviceKeyEvent, ack: Bool) {
        switch event {
        case .down:
            let owner: KeyPressTracker.Owner = ack ? .agentAck : (list != nil ? .switcher : .normal)
            guard let owner = presses.began(key, owner: owner) else { return }
            if owner == .agentAck { agent.dismiss(fromDevice: true); return }
            owner == .switcher ? listPressBegan(key) : pressBegan(key)
        case .long:
            guard let owner = presses.longPressed(key) else { return }
            switch owner {
            case .normal: longPressed(key)
            case .switcher: if key == .down { closeList() }
            case .agentAck, .ignored: break
            }
        case .up:
            guard let (owner, isTap) = presses.ended(key) else { return }
            switch owner {
            case .normal: pressEnded(key, isTap: isTap)
            case .switcher: if key == .down, isTap { moveList(by: 1) }
            case .agentAck, .ignored: break
            }
        }
    }

    /// 当前是否处于"字幕模式"(设备模式为字幕)。
    private var inCaptionsMode: Bool { mode == .sub }

    /// 按下:OK 立即响应(按住说话需要马上开麦);上下键要等松开或长按才知道是哪种手势。
    private func pressBegan(_ key: DeviceKey) {
        guard key == .ok else { return }
        // 听写进行中(包括从 Mac 上开始的):OK 交给听写,与屏幕上的停止 / 麦克风提示一致。
        if dictation.phase.isBusy {
            dictation.pressDown(mode: dictation.mode)
            okDrivesDictation = true
        } else if inCaptionsMode {
            // Mac 上正显示模态提示框(如"结束字幕?")时不开 / 停字幕,避免叠加弹框。
            guard NSApp.modalWindow == nil else { return }
            subtitles.isRunning ? hooks.stopCaptions() : openCaptionAppPicker()
        } else {
            dictation.pressDown(mode: mode == .tr ? .translate : .dictate)
            okDrivesDictation = true
        }
    }

    private func longPressed(_ key: DeviceKey) {
        switch key {
        case .up:
            guard !dictation.phase.isBusy else { return }
            cycleMode()
        case .down:
            if dictation.phase.isBusy {
                dictation.cancel()
            } else if !inCaptionsMode {
                perform(settings.deviceDownLongAction)
            }
        case .ok:
            break  // OK 长按就是按住说话,松开时结束
        }
    }

    /// 松开:OK 结束按住说话(仅听写 / 翻译模式);上下键只有短按(没触发长按)才执行短按动作。
    private func pressEnded(_ key: DeviceKey, isTap: Bool) {
        switch key {
        case .ok:
            if okDrivesDictation {
                okDrivesDictation = false
                dictation.pressUp()
            }
        case .up:
            guard isTap, !dictation.phase.isBusy else { return }
            if inCaptionsMode {
                if subtitles.isRunning {
                    // 和 Mac 上的翻译开关一致:翻译不可用时不能切换(提示图标此时也隐藏)。
                    if hooks.canTranslate() { settings.subtitleTranslate.toggle() }
                } else {
                    cycleMode()  // 没有字幕时上键提示是"切换模式"
                }
            } else {
                perform(settings.deviceUpAction)
            }
        case .down:
            guard isTap, !dictation.phase.isBusy else { return }
            if inCaptionsMode {
                if subtitles.isRunning { hooks.toggleSubtitleBar() }
            } else {
                perform(settings.deviceDownAction)
            }
        }
    }

    private func perform(_ action: KeyAction) {
        switch action {
        case .pasteLast: dictation.reinsertLast()
        case .nextMode: cycleMode()
        case .appSwitcher: openAppSwitcher()
        default: KeySender.perform(action)
        }
        // 用户开始回应 Agent,顺手清掉"等待输入"提醒(设备上的也一起清)。
        if agent.current != nil { agent.dismiss() }
    }

    private func cycleMode() {
        let all: [DeviceMode] = [.dict, .tr, .sub]
        let index = all.firstIndex(of: mode) ?? 0
        mode = all[(index + 1) % all.count]
        sync()
    }

    // MARK: - 列表页

    /// 切换应用:默认选中第二个应用(最前面的是当前应用,和 ⌘Tab 一样)。
    private func openAppSwitcher() {
        let apps = AppSwitcher.list()
        guard !apps.isEmpty else { return }
        openList(ListSession(purpose: .switchApp(apps), selected: apps.count > 1 ? 1 : 0))
    }

    /// 选择字幕应用:正在出声的应用排在前面并默认选中第一个。
    private func openCaptionAppPicker() {
        let apps = AudioProcesses.runningApps()
        guard !apps.isEmpty else {
            // 走正常的状态同步(而不是直接发),重连后不会重放过期的错误页。
            deviceError = ("NO APPS", Date().addingTimeInterval(Self.errorHold))
            lastState = nil
            sync()
            return
        }
        openList(ListSession(purpose: .pickCaptionApp(apps), selected: 0))
    }

    private func openList(_ session: ListSession) {
        list = session
        lastState = nil
        sync()
    }

    /// 列表里按下:上键没有长按动作,按下即移动;OK 按下即确认;下键等松开(短按移动)或长按(关闭)。
    private func listPressBegan(_ key: DeviceKey) {
        guard let current = list else { return }
        switch key {
        case .up:
            moveList(by: -1)
        case .ok:
            closeList()
            switch current.purpose {
            case .switchApp(let apps):
                AppSwitcher.activate(apps[current.selected])
            case .pickCaptionApp(let apps):
                // 列表打开期间 Mac 上已经开始了字幕,或正显示对话框:只关闭列表,
                // 不从设备触发 Mac 上的确认框(设备上没法回答)。
                guard !subtitles.isRunning, NSApp.modalWindow == nil else { return }
                hooks.startCaptions(apps[current.selected])
            }
        case .down:
            break
        }
    }

    private func moveList(by delta: Int) {
        guard var current = list, current.count > 0 else { return }
        current.selected = (current.selected + delta + current.count) % current.count
        current.touched = Date()
        list = current
        sendList()
    }

    private func closeList() {
        list = nil
        presses.lockOut(.ok, for: okLockoutAfterList)
        lastState = nil
        sync()
    }

    private func sendList() {
        guard let list else { return }
        link.sendList(title: list.title, items: list.names, selected: list.selected)
    }

    // MARK: - 状态同步

    private func sync() {
        guard link.connection != .disconnected else { return }

        let config = DeviceConfig(
            passportMic: settings.micID == AppSettings.passportMicID,
            engine: ModelCatalog.model(settings.dictationModelID)?.shortName ?? "",
            screenOff: settings.deviceScreenOff,
            sound: settings.soundEffects)
        if config != lastConfig {
            lastConfig = config
            link.sendConfig(config)
        }

        // 列表打开时开始了听写(Mac 上触发):设备已切到录音页,关闭列表,按键不再归列表。
        if list != nil, dictation.phase.isBusy {
            list = nil
            lastState = nil
        }
        if let current = list, Date().timeIntervalSince(current.touched) > listTimeout {
            closeList()
            return
        }
        let state = currentState()
        if lastState != state {
            lastState = state
            link.sendState(state.ui, mode: state.mode, msg: state.msg)
            if state.ui == .list { sendList() }
        }
        let hints = DeviceStateMapper.keyHints(
            state: state.ui, deviceMode: mode, handsFree: dictation.isHandsFree,
            canTranslate: hooks.canTranslate(), up: settings.deviceUpAction, down: settings.deviceDownAction)
        link.sendKeyHints(ok: hints.ok, up: hints.up, down: hints.down)
        switch state.ui {
        case .rec: link.sendLevel(Int(dictation.level * 100))
        case .sub: link.sendLevel(Int(subtitles.level * 100))
        default: break
        }
    }

    /// 错误页停留时长(与固件 ERR_HOLD_MS 一致)。
    static let errorHold: TimeInterval = 2.0

    private func currentState() -> DeviceStateMapper.State {
        if let error = deviceError {
            if Date() < error.until, !dictation.phase.isBusy { return .init(ui: .err, mode: mode, msg: error.msg) }
            deviceError = nil
        }
        if list != nil, !dictation.phase.isBusy { return .init(ui: .list, mode: mode, msg: "") }
        return DeviceStateMapper.state(
            phase: dictation.phase, dictationMode: dictation.mode, deviceMode: mode,
            subtitlesRunning: subtitles.isRunning, subtitleApp: subtitles.appName)
    }
}
