import AppKit

/// 把 Passport 设备接到听写、字幕和 vibe coding 动作上:
/// - 设备按键 → 手势(KeyPressTracker)→ 听写 / 字幕 / 快捷键 / 列表动作;
/// - app 状态 → 设备界面(state / level / keys / config / list),Agent 通知 → 设备通知层。
/// 用 16 Hz 定时器比较差异后下发,不需要各控制器主动通知,保持解耦。
///
/// 交互规则(docs/architecture.md「Passport 按键」):
/// - 显示与按键分开:字幕在运行时设备显示字幕页(不管哪个模式);按键含义由设备模式决定。
/// - OK:听写进行中始终交给听写;Passport 按住说话,短于 250 ms 取消;否则听写 / 翻译模式是说话,
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
        /// 当前翻译方式是否可用(系统语言包已下载 / 在线服务已配置 / AI 已配置)。
        var canTranslate: () -> Bool
    }

    /// 设备上的列表页:切换应用,或为字幕选择应用。
    private struct ListSession {
        enum Purpose {
            case switchApp([SwitchableApp])
            case pickCaptionApp([AudioApp])
            /// Agent App 的项目列表：固定项（SWITCH APP / RECENT）+ 项目。
            case pickProject(catalog: AgentSessionCatalog, choices: [AgentProjectChoice])
            /// 某个项目或 RECENT 下的会话列表。
            case pickSession(catalog: AgentSessionCatalog, project: AgentProject?, sessions: [AgentSession])
        }

        let purpose: Purpose
        var selected: Int
        var touched = Date()

        var title: String {
            switch purpose {
            case .switchApp: "SWITCH APP"
            case .pickCaptionApp: "CAPTIONS"
            case .pickProject(let catalog, _): "\(catalog.app.shortName) PROJECT"
            case .pickSession(let catalog, _, _): "\(catalog.app.shortName) SESSION"
            }
        }

        var names: [String] {
            switch purpose {
            case .switchApp(let apps): apps.map(\.name)
            case .pickCaptionApp(let apps): apps.map { $0.isPlaying ? "\($0.name) *" : $0.name }
            case .pickProject(_, let choices): choices.map(\.displayName)
            case .pickSession(_, _, let sessions): sessions.map(\.displayName)
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
    private let codex: CodexActionCoordinator
    private let settings: AppSettings
    private let inputTarget: DeviceInputTarget
    private let threadNavigator: CodexThreadNavigator
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
    /// ACK 按下时绑定当时显示的卡片，松开时才打开。续聊期间保持原会话约束。
    private var noticePresses: [DeviceKey: AgentNotifier.Notice] = [:]
    private var followupChat: CodexThreadNavigator.ActiveChat?
    private var openingNotice: Task<Void, Never>?
    private var followupActionInFlight = false
    /// 列表关闭后忽略 OK 新按下的时长(防抖,避免误触听写)。
    private let okLockoutAfterList: TimeInterval = 0.25
    /// 这次 OK 按下交给了听写:松开发 pressUp;断线 / 切换链路时取消,避免丢失松开事件后误输入。
    private var okDrivesDictation = false
    /// 设备上的临时错误提示(如没有可选的应用),到期前代替正常状态显示,时长与固件的错误页一致。
    private var deviceError: (msg: String, until: Date)?
    /// 上键发送 / 下键停止的结果页，让操作后无需看 Mac 就能知道是否成功。
    private var codexStatus: (ui: DeviceUIState, msg: String, until: Date)?
    /// 正在读取某个 Agent 的项目 / 会话；设备显示 SCANNING，按键暂不响应。
    private var scanningSessionApp: AgentSessionApp?
    private var sessionScanTask: Task<Void, Never>?
    /// 正在打开选中的会话（AXPress + 等窗口切换 + 聚焦输入框）。
    private var openingSessionApp: AgentSessionApp?
    private var sessionOpenTask: Task<Void, Never>?
    /// 进入 Agent 后先显示用量首页；短按 OK 进入 READY，长按 OK 直接说话。
    private struct UsageHome {
        let app: AgentSessionApp
        var snapshot: AgentUsageSnapshot?
        var tab = 0
        let token = UUID()
    }
    private var usageHome: UsageHome?
    private var usageHomeVisible = false
    private var usageTask: Task<Void, Never>?
    /// 这次 OK 按下的时刻；READY 页短按(<500 ms)回到用量首页，长按仍是说话。
    private var okPressStartedAt: TimeInterval?

    init(link: DeviceLink, dictation: DictationController, subtitles: SubtitleController,
         agent: AgentNotifier, codex: CodexActionCoordinator, settings: AppSettings,
         threadNavigator: CodexThreadNavigator, hooks: Hooks) {
        self.link = link
        self.dictation = dictation
        self.subtitles = subtitles
        self.agent = agent
        self.codex = codex
        self.settings = settings
        self.inputTarget = DeviceInputTarget(settings: settings)
        self.threadNavigator = threadNavigator
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
            let message = notice.threadID == nil ? notice.source : "OK OPEN " + (notice.project ?? notice.source)
            link.sendAgent(event, msg: message)
        }
        let timer = Timer(timeInterval: 1.0 / 16, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        // 加到 common 模式:菜单打开、模态提示框(如"保存字幕吗?")显示时设备状态也继续同步。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 连接变化(断开、重连、USB / 蓝牙切换):
    /// - 正按着 OK 说话:松开事件可能丢了,取消本次听写,避免断线后意外输入;
    /// - 用 Passport 麦克风录音时设备断开:取消这次录音,避免截断内容被当作完整输入;
    /// - 强制重发全部状态,清掉未完成的按压和列表;还没处理的 Agent 提醒重新发给设备。
    private func connectionChanged(_ connection: DeviceLink.Connection) {
        sessionScanTask?.cancel()
        sessionScanTask = nil
        sessionOpenTask?.cancel()
        sessionOpenTask = nil
        usageTask?.cancel()
        usageTask = nil
        scanningSessionApp = nil
        openingSessionApp = nil
        if okDrivesDictation {
            okDrivesDictation = false
            dictation.cancel()
        }
        let recording = dictation.phase == .recording || dictation.phase == .starting
        if connection == .disconnected, settings.micID == AppSettings.passportMicID, recording {
            dictation.cancel()
        }
        presses.reset()
        noticePresses.removeAll()
        list = nil
        lastState = nil
        lastConfig = nil
        sync()
        if connection != .disconnected, let notice = agent.current {
            agent.onNotice?(notice)
        }
        if connection != .disconnected, let home = usageHome, usageHomeVisible {
            beginUsageHome(for: home.app)
        }
    }

    // MARK: - 按键

    /// 原始按键 → 手势 → 动作。手势规则见 `KeyPressTracker`(按压归属、松开判定短按、防抖锁定)。
    private func handle(_ key: DeviceKey, _ event: DeviceKeyEvent, ack: Bool) {
        switch event {
        case .down:
            let blocked = openingNotice != nil || followupActionInFlight
            let owner: KeyPressTracker.Owner = ack ? .agentAck : (blocked ? .ignored : (list != nil ? .switcher : .normal))
            guard let owner = presses.began(key, owner: owner) else { return }
            if owner == .agentAck { noticePresses[key] = agent.current; return }
            if owner == .ignored { return }
            owner == .switcher ? listPressBegan(key) : pressBegan(key)
        case .long:
            guard let owner = presses.longPressed(key) else { return }
            switch owner {
            case .normal: longPressed(key)
            case .switcher: if key == .down { listLongPressed() }
            case .agentAck, .ignored: break
            }
        case .up:
            guard let (owner, isTap) = presses.ended(key) else { return }
            switch owner {
            case .normal: pressEnded(key, isTap: isTap)
            case .switcher: if key == .down, isTap { moveList(by: 1) }
            case .agentAck:
                guard let notice = noticePresses.removeValue(forKey: key), agent.current == notice else { break }
                if key == .ok, isTap { openNotice(notice, fromDevice: true) }
                else { agent.dismiss(fromDevice: true) }
            case .ignored: break
            }
        }
    }

    /// Mac 胶囊和设备 ACK 共用入口。打开过程中保持按键隔离，避免同一次按压启动录音。
    func openNotice(_ notice: AgentNotifier.Notice, fromDevice: Bool = false) {
        guard agent.current == notice else { return }
        guard let thread = notice.threadID else { agent.dismiss(fromDevice: fromDevice); return }
        guard !dictation.phase.isBusy, openingNotice == nil, !followupActionInFlight else { return }
        clearUsageHome()
        agent.pauseCompletedNotices()
        agent.dismiss(fromDevice: fromDevice)
        followupChat = nil
        mode = .dict
        openingNotice = Task { [weak self] in
            guard let self else { return }
            defer { openingNotice = nil; lastState = nil; sync() }
            do {
                followupChat = try await threadNavigator.open(thread)
                codexStatus = (.done, "READY TO TALK", Date().addingTimeInterval(2))
            } catch {
                codexStatus = (.err, "OPEN CODEX", Date().addingTimeInterval(2))
                agent.resumeCompletedNotices()
            }
        }
        lastState = nil
        sync()
    }

    /// 当前是否处于"字幕模式"(设备模式为字幕)。
    private var inCaptionsMode: Bool { mode == .sub }

    /// 按下:OK 立即响应(按住说话需要马上开麦);上下键要等松开或长按才知道是哪种手势。
    private func pressBegan(_ key: DeviceKey) {
        if key == .ok { okPressStartedAt = ProcessInfo.processInfo.systemUptime }
        // 用量首页:OK 先不动作,等松开判定为“进入 READY”或长按判定为“直接说话”;
        // 上下键等松开后切 Tab。
        if usageHome != nil, usageHomeVisible { return }
        guard key == .ok else { return }
        guard scanningSessionApp == nil, openingSessionApp == nil else { return }
        // 上一句还在处理(识别 / 润色 / 翻译):OK 不可用,不开始新的一句;设备上提示列是禁用色并给出"不可用"反馈。
        if case .processing = dictation.phase { return }
        // 录音进行中(包括从 Mac 上开始的):OK 交给听写,与屏幕上的停止 / 麦克风提示一致。
        if dictation.phase.isBusy {
            dictation.pressDown(mode: dictation.mode, style: .pushToTalk)
            okDrivesDictation = true
        } else if inCaptionsMode {
            // Mac 上正显示模态提示框(换应用 / 退出的确认)时不开 / 停字幕,避免叠加弹框。
            // 字幕条上的「结束字幕？」气泡不算:设备上结束不询问,会直接结束并收起气泡。
            guard NSApp.modalWindow == nil else { return }
            subtitles.isRunning ? hooks.stopCaptions() : openCaptionAppPicker()
        } else {
            // 录音／翻译属于通用语音输入；按键映射不能把它们强制绑定到 Codex 的空闲空输入框。
            // 上键发送时再由 Codex 编排读取当前草稿并核对目标，录音本身只输入文字、不提交消息。
            if followupChat != nil {
                startFollowupDictation()
                return
            }
            dictation.pressDown(mode: mode == .tr ? .translate : .dictate, style: .pushToTalk,
                                prepareTarget: { [inputTarget, codex] in
                                    let target = try await inputTarget.prepare()
                                    if target.bundleIdentifier == AccessibilityCodexDesktopAdapter.bundleIdentifier {
                                        await codex.prepareNewDictation()
                                    }
                                    return target
                                })
            okDrivesDictation = true
        }
    }

    private func startFollowupDictation() {
        var recordingChat: CodexThreadNavigator.ActiveChat?
        dictation.pressDown(mode: mode == .tr ? .translate : .dictate, style: .pushToTalk,
                            prepareTarget: { [threadNavigator, codex] in
                                let chat = try await threadNavigator.prepareCurrentChat()
                                guard let app = NSRunningApplication(processIdentifier: chat.target.processID) else {
                                    throw DeviceInputTarget.Failure.unavailable
                                }
                                await codex.prepareNewDictation()
                                try Task.checkCancellation()
                                Log.codex.info("follow-up: recording target ready, thread link=\(chat.threadID != nil)")
                                recordingChat = chat
                                return app
                            }, validateInsertion: { [weak self, threadNavigator] in
                                guard let recordingChat, try await threadNavigator.currentChat() == recordingChat else {
                                    throw DeviceInputTarget.Failure.noInput
                                }
                                self?.followupChat = recordingChat
                            })
        okDrivesDictation = true
    }

    private func longPressed(_ key: DeviceKey) {
        if usageHome != nil, usageHomeVisible {
            if key == .ok {
                // 长按 OK:不先进 READY,直接从用量页开始录音。
                hideUsageHome()
                pressBegan(.ok)
                return
            }
            clearUsageHome()
        }
        switch key {
        case .up:
            guard !dictation.phase.isBusy else { return }
            cycleMode()
        case .down:
            guard scanningSessionApp == nil, openingSessionApp == nil else { return }
            if dictation.phase.isBusy {
                dictation.cancel()
            } else if !inCaptionsMode {
                followupChat = nil
                agent.resumeCompletedNotices()
                if settings.deviceDownLongAction == .appSwitcher {
                    openContextSwitcher()
                } else {
                    perform(settings.deviceDownLongAction)
                }
            }
        case .ok:
            break  // OK 长按就是按住说话,松开时结束
        }
    }

    /// 松开:OK 结束按住说话(仅听写 / 翻译模式);上下键只有短按(没触发长按)才执行短按动作。
    private func pressEnded(_ key: DeviceKey, isTap: Bool) {
        if usageHome != nil, usageHomeVisible, isTap {
            switch key {
            case .ok:
                hideUsageHome()
            case .up:
                moveUsageTab(-1)
            case .down:
                moveUsageTab(1)
            }
            return
        }
        switch key {
        case .ok:
            let held = okPressStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 }
            okPressStartedAt = nil
            if let held, held < 0.5, usageHome != nil, !usageHomeVisible,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == usageHome?.app.bundleID {
                okDrivesDictation = false
                dictation.cancel()
                showUsageHome()
                return
            }
            if okDrivesDictation {
                okDrivesDictation = false
                dictation.pressUp()
            }
        case .up:
            guard isTap, !dictation.phase.isBusy else { return }
            if inCaptionsMode {
                if subtitles.isRunning {
                    // 和字幕条「译」菜单是同一个开关(只对本场字幕有效);当前翻译方式不可用时不能切换(提示图标此时也隐藏)。
                    if hooks.canTranslate() { subtitles.toggleTranslation() }
                } else {
                    cycleMode()  // 没有字幕时上键提示是"切换模式"
                }
            } else {
                if let chat = followupChat { performFollowup(chat, send: true) }
                else { perform(settings.deviceUpAction) }
            }
        case .down:
            guard isTap, !dictation.phase.isBusy else { return }
            if inCaptionsMode {
                if subtitles.isRunning { hooks.toggleSubtitleBar() }
            } else {
                if let chat = followupChat { performFollowup(chat, send: false) }
                else { perform(settings.deviceDownAction) }
            }
        }
    }

    private func performFollowup(_ chat: CodexThreadNavigator.ActiveChat, send: Bool) {
        guard !followupActionInFlight, openingNotice == nil else { return }
        followupActionInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { followupActionInFlight = false }
            do {
                let current = try await threadNavigator.currentChat()
                guard followupChat == chat else { return }
                // 已建立的会话允许输入框重新渲染。尚无链接时，必须仍是同一个输入目标。
                let matches = chat.threadID.map { current.threadID == $0 } ?? (current == chat)
                guard matches else {
                    publish(.targetChanged)
                    return
                }
                let target = current.target
                if send { await codex.send(expectedTarget: target) }
                else { await codex.stop(target: target) }
                publish(codex.outcome)
                if codex.outcome == .accepted { agent.resumeCompletedNotices() }
            } catch { publish(.targetChanged) }
        }
    }

    private func perform(_ action: KeyAction) {
        switch action {
        case .codexSend:
            Task { [weak self] in
                guard let self else { return }
                do {
                    let target = try await inputTarget.prepare()
                    if target.bundleIdentifier == AccessibilityCodexDesktopAdapter.bundleIdentifier {
                        await codex.send()
                        publish(codex.outcome)
                    } else {
                        // 明确选定的其他应用使用普通回车映射；不作为 Codex AX 失败的兜底。
                        KeySender.perform(.enter)
                        codexStatus = (.done, "ENTER", Date().addingTimeInterval(1.2))
                        lastState = nil; sync()
                    }
                } catch { publish(.checkMac) }
            }
        case .codexStop:
            Task { [weak self] in
                guard let self else { return }
                do {
                    let target = try await inputTarget.prepare()
                    if target.bundleIdentifier == AccessibilityCodexDesktopAdapter.bundleIdentifier {
                        await codex.stopCurrent()
                        publish(codex.outcome)
                    } else {
                        KeySender.perform(.escape)
                        codexStatus = (.done, "ESC", Date().addingTimeInterval(1.2))
                        lastState = nil; sync()
                    }
                } catch { publish(.checkMac) }
            }
        case .pasteLast: dictation.reinsertLast()
        case .nextMode: cycleMode()
        case .appSwitcher: openAppSwitcher()
        default: KeySender.perform(action)
        }
        // 用户开始回应 Agent,顺手清掉"等待输入"提醒(设备上的也一起清)。
        if agent.current != nil { agent.dismiss() }
    }

    /// Codex 动作只在 AX 已确认同一聊天、同一输入框时执行；显示短结果页，不把未确认写成成功。
    private func publish(_ outcome: CodexActionCoordinator.Outcome) {
        let status: (DeviceUIState, String)
        switch outcome {
        case .accepted: status = (.done, "SENT")
        case .stopped: status = (.done, "STOPPED")
        case .noDraft: status = (.err, "INPUT EMPTY")
        case .noTask: status = (.idle, "")
        case .expired: status = (.err, "DRAFT EXPIRED")
        case .targetChanged, .checkMac: status = (.err, "CHECK MAC")
        case .busy: status = (.err, "BUSY")
        case .uncertain: status = (.err, "UNSURE")
        case .ready: return
        }
        codexStatus = (status.0, status.1, Date().addingTimeInterval(2))
        lastState = nil
        sync()
    }

    private func cycleMode() {
        let all: [DeviceMode] = [.dict, .tr, .sub]
        let index = all.firstIndex(of: mode) ?? 0
        mode = all[(index + 1) % all.count]
        sync()
    }

    // MARK: - 列表页

    /// 切换应用：默认选中已记住的目标，确认后供下一次远程语音输入使用。
    private func openAppSwitcher(preferredBundleID: String? = nil) {
        let apps = AppSwitcher.list()
        guard !apps.isEmpty else { return }
        let preferred = preferredBundleID ?? settings.deviceTargetBundleID
        let selected = apps.firstIndex { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier == preferred } ?? 0
        openList(ListSession(purpose: .switchApp(apps), selected: selected))
    }

    /// 长按下键的「切换应用 / 会话」入口：先尝试把当前 App 当作 Agent 读取项目 / 会话；
    /// 读不到（普通应用、没有聊天输入框）时回退到应用列表。
    /// 这里不按 Bundle ID 白名单判断，WorkBuddy / ZCode / Claude / 豆包 / 千问等新 Agent 都能自动识别。
    private func openContextSwitcher() {
        guard sessionScanTask == nil, openingSessionApp == nil else { return }
        clearUsageHome()
        guard let target = currentAgentApp() else {
            openAppSwitcher()
            return
        }
        scanningSessionApp = target
        lastState = nil
        sync()
        sessionScanTask = Task { [weak self] in
            guard let self else { return }
            let catalog = await AgentSessionCatalogLoader.load(for: target)
            guard !Task.isCancelled else { return }
            self.scanningSessionApp = nil
            self.sessionScanTask = nil
            if let catalog, !catalog.isEmpty {
                self.openProjectList(catalog)
            } else {
                self.openAppSwitcher()
            }
        }
    }

    /// 前置的普通应用优先；VibeKey 自己在前台时用设备记住的目标应用。
    /// 是否真的有项目 / 会话由 `AgentSessionCatalogLoader.load` 实际探测。
    private func currentAgentApp() -> AgentSessionApp? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
           frontmost.activationPolicy == .regular,
           let app = AgentSessionApp(running: frontmost) {
            return app
        }
        let identifier = settings.deviceTargetBundleID
        guard !identifier.isEmpty,
              let running = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == identifier && !$0.isTerminated
              }),
              let app = AgentSessionApp(running: running) else { return nil }
        return app
    }

    private func openProjectList(_ catalog: AgentSessionCatalog) {
        var choices: [AgentProjectChoice] = [.switchApp]
        if !catalog.recent.isEmpty { choices.append(.recent) }
        choices.append(contentsOf: catalog.projects.map { .project($0) })
        guard choices.count > 1 else {
            openAppSwitcher()
            return
        }
        let current = choices.firstIndex {
            if case .project(let project) = $0 { return project.isCurrent }
            return false
        }
        let firstWithSessions = choices.firstIndex {
            if case .project(let project) = $0 { return !project.sessions.isEmpty }
            return false
        }
        let selected = current ?? firstWithSessions ?? min(1, choices.count - 1)
        list = ListSession(purpose: .pickProject(catalog: catalog, choices: choices), selected: selected)
        lastState = nil
        sync()
    }

    private func choose(_ choice: AgentProjectChoice, catalog: AgentSessionCatalog) {
        switch choice {
        case .switchApp:
            openAppSwitcher(preferredBundleID: catalog.app.bundleID)
        case .recent:
            openSessionList(catalog, project: nil, sessions: catalog.recent)
        case .project(let project):
            loadProjectSessions(project, catalog: catalog)
        }
    }

    /// 读取项目会话可能触发侧栏展开，短暂显示 SCANNING；完成后进入 SESSION 列表。
    private func loadProjectSessions(_ project: AgentProject, catalog: AgentSessionCatalog) {
        guard sessionScanTask == nil else { return }
        scanningSessionApp = catalog.app
        list = nil
        lastState = nil
        sync()
        sessionScanTask = Task { [weak self] in
            guard let self else { return }
            let sessions = await AgentSessionCatalogLoader.sessions(for: project, in: catalog.app)
            guard !Task.isCancelled else { return }
            self.scanningSessionApp = nil
            self.sessionScanTask = nil
            guard !sessions.isEmpty else {
                self.deviceError = ("NO SESSIONS", Date().addingTimeInterval(Self.errorHold))
                self.lastState = nil
                self.sync()
                return
            }
            let updatedProject = AgentProject(
                name: project.name, index: project.index, sessions: sessions,
                isCurrent: project.isCurrent || sessions.contains(where: \.isCurrent))
            let projects = catalog.projects.map {
                $0.index == project.index && $0.name == project.name ? updatedProject : $0
            }
            let updated = AgentSessionCatalog(app: catalog.app, projects: projects, recent: catalog.recent)
            self.openSessionList(updated, project: updatedProject, sessions: sessions)
        }
    }

    private func openSessionList(_ catalog: AgentSessionCatalog, project: AgentProject?,
                                 sessions: [AgentSession]) {
        guard !sessions.isEmpty else {
            list = nil
            deviceError = ("NO SESSIONS", Date().addingTimeInterval(Self.errorHold))
            lastState = nil
            sync()
            return
        }
        let selected = sessions.firstIndex(where: \.isCurrent) ?? 0
        list = ListSession(purpose: .pickSession(catalog: catalog, project: project, sessions: sessions),
                           selected: selected)
        lastState = nil
        sync()
    }

    private func openSession(_ session: AgentSession, project: AgentProject?, app: AgentSessionApp) {
        guard sessionOpenTask == nil, openingSessionApp == nil else { return }
        clearUsageHome()
        openingSessionApp = app
        lastState = nil
        sync()
        sessionOpenTask = Task { [weak self] in
            guard let self else { return }
            let opened = await AgentSessionCatalogLoader.open(project: project, session: session, in: app)
            guard !Task.isCancelled else { return }
            self.openingSessionApp = nil
            self.sessionOpenTask = nil
            if opened {
                self.settings.deviceTargetBundleID = app.bundleID
                self.settings.deviceTargetName = app.targetName
                self.followupChat = nil
                self.usageHome = UsageHome(app: app)
                self.usageHomeVisible = false
                self.codexStatus = (.done, "READY TO TALK", Date().addingTimeInterval(2))
            } else {
                self.codexStatus = (.err, "OPEN SESSION", Date().addingTimeInterval(2))
            }
            self.lastState = nil
            self.sync()
        }
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

    // MARK: - Agent 用量首页

    /// 切换到 Agent 应用后先显示用量首页；读完数据再刷新同一页。
    private func beginUsageHome(for app: AgentSessionApp) {
        let home = UsageHome(app: app)
        usageHome = home
        usageHomeVisible = true
        lastState = nil
        sync()
        loadUsageHome(home)
    }

    private func showUsageHome() {
        guard let home = usageHome else { return }
        usageHomeVisible = true
        lastState = nil
        sync()
        loadUsageHome(home)
    }

    private func hideUsageHome() {
        guard usageHome != nil, usageHomeVisible else { return }
        usageHomeVisible = false
        lastState = nil
        sync()
    }

    private func loadUsageHome(_ home: UsageHome) {
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            let snapshot = await AgentUsageService.load(for: home.app)
            guard !Task.isCancelled, let self, self.usageHome?.token == home.token else { return }
            self.usageHome?.snapshot = snapshot
            self.lastState = nil
            self.sync()
        }
    }

    private func clearUsageHome() {
        guard usageHome != nil else { return }
        usageHome = nil
        usageHomeVisible = false
        usageTask?.cancel()
        usageTask = nil
        lastState = nil
        sync()
    }

    private func moveUsageTab(_ delta: Int) {
        guard var home = usageHome else { return }
        home.tab = (home.tab + delta + 3) % 3
        usageHome = home
        lastState = nil
        sync()
    }

    private func deviceUsage(_ home: UsageHome) -> DeviceUsage {
        home.snapshot?.device(tab: home.tab) ?? DeviceUsage(
            app: home.app.shortName, today: "", week: "", total: "", tab: home.tab,
            leftPercent: nil, reset: "", plan: "", credits: nil, ready: false)
    }

    /// 列表里按下:上键没有长按动作,按下即移动;OK 按下即确认;下键等松开(短按移动)或长按(关闭)。
    private func listPressBegan(_ key: DeviceKey) {
        guard let current = list else { return }
        switch key {
        case .up:
            moveList(by: -1)
        case .ok:
            switch current.purpose {
            case .switchApp(let apps):
                guard apps.indices.contains(current.selected) else { closeList(); return }
                closeList()
                if let running = NSRunningApplication(processIdentifier: apps[current.selected].pid),
                   let identifier = running.bundleIdentifier {
                    settings.deviceTargetBundleID = identifier
                    settings.deviceTargetName = apps[current.selected].name
                }
                AppSwitcher.activate(apps[current.selected])
                if let running = NSRunningApplication(processIdentifier: apps[current.selected].pid),
                   let app = AgentSessionApp(running: running),
                   AgentAppDisplayName.isKnownAgent(bundleID: app.bundleID) {
                    beginUsageHome(for: app)
                } else {
                    clearUsageHome()
                }
            case .pickCaptionApp(let apps):
                guard apps.indices.contains(current.selected) else { closeList(); return }
                closeList()
                // 列表打开期间 Mac 上已经开始了字幕,或正显示对话框:只关闭列表,
                // 不从设备触发 Mac 上的确认框(设备上没法回答)。
                guard !subtitles.isRunning, NSApp.modalWindow == nil else { return }
                hooks.startCaptions(apps[current.selected])
            case .pickProject(let catalog, let choices):
                guard choices.indices.contains(current.selected) else { closeList(); return }
                choose(choices[current.selected], catalog: catalog)
            case .pickSession(let catalog, let project, let sessions):
                guard sessions.indices.contains(current.selected) else { closeList(); return }
                let session = sessions[current.selected]
                closeList()
                openSession(session, project: project, app: catalog.app)
            }
        case .down:
            break
        }
    }

    /// 长按下键在列表里的含义：会话页返回项目页；其余列表关闭。
    private func listLongPressed() {
        guard let current = list else { return }
        if case .pickSession(let catalog, _, _) = current.purpose {
            openProjectList(catalog)
        } else {
            closeList()
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
        if usageHome != nil, usageHomeVisible, dictation.phase.isBusy {
            usageHome = nil
            usageTask?.cancel()
            usageTask = nil
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
        if state.ui == .sub {
            let captions = subtitles.feed.captions
            link.sendCaption(app: subtitles.appName,
                             src: captions.sourceFinal + captions.sourceLive,
                             dst: captions.translation,
                             live: !captions.sourceLive.isEmpty || !captions.translationLive.isEmpty)
        } else {
            link.sendCaption(app: "", src: "", dst: "", live: false)
        }
        if state.ui == .usage, let home = usageHome {
            link.sendUsage(deviceUsage(home))
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
        if openingNotice != nil { return .init(ui: .proc, mode: mode, msg: "OPENING CODEX") }
        if scanningSessionApp != nil { return .init(ui: .proc, mode: mode, msg: "SCANNING") }
        if openingSessionApp != nil { return .init(ui: .proc, mode: mode, msg: "OPEN SESSION") }
        if let error = deviceError {
            if Date() < error.until, !dictation.phase.isBusy { return .init(ui: .err, mode: mode, msg: error.msg) }
            deviceError = nil
        }
        if let status = codexStatus {
            if Date() < status.until, !dictation.phase.isBusy {
                return .init(ui: status.ui, mode: mode, msg: status.msg)
            }
            codexStatus = nil
        }
        if list != nil, !dictation.phase.isBusy { return .init(ui: .list, mode: mode, msg: "") }
        if usageHome != nil, usageHomeVisible, !dictation.phase.isBusy { return .init(ui: .usage, mode: mode, msg: "") }
        if let started = okPressStartedAt, usageHome != nil, !usageHomeVisible,
           ProcessInfo.processInfo.systemUptime - started < 0.5,
           dictation.phase == .starting || dictation.phase == .recording,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == usageHome?.app.bundleID {
            return .init(ui: .idle, mode: mode, msg: "TAP OK: USAGE")
        }
        let state = DeviceStateMapper.state(
            phase: dictation.phase, dictationMode: dictation.mode, deviceMode: mode,
            subtitlesRunning: subtitles.isRunning, subtitleApp: subtitles.appName)
        if state.ui == .idle, let home = usageHome, !usageHomeVisible,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == home.app.bundleID {
            return .init(ui: .idle, mode: state.mode, msg: "TAP OK: USAGE")
        }
        return state
    }
}
