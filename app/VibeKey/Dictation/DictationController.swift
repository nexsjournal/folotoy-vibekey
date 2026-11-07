import AppKit

/// 听写流程的状态机:录音 → 识别 → (润色 / 翻译)→ 输入。
/// 只负责编排,具体能力通过注入的依赖完成:
/// - `makeSource`:按设置创建音源(系统麦克风或 Passport);
/// - `engines`:按模型 ID 拿可用的识别引擎;
/// - `postProcessor`:润色 / 翻译;`inserter`:把文本输入到焦点窗口。
/// 取消约定:`cancel()` 之后,进行中的流程在每个 `await` 返回时检查 `Task.isCancelled` 并直接退出,
/// 不再改状态、不再粘贴,也不报错(用户主动放弃不是失败)。
@MainActor @Observable
final class DictationController {
    enum Mode: Equatable, Sendable {
        case dictate
        case translate
    }

    enum Phase: Equatable {
        case idle
        /// 正在加载模型 / 打开麦克风。
        case starting
        case recording
        /// 处理中(加载模型 / 识别 / 润色 / 翻译)。
        case processing(ProcessingStep)
        case done(DictationResult)
        case failed(DictationFailure)

        var isBusy: Bool {
            switch self {
            case .idle, .done, .failed: false
            default: true
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var mode: Mode = .dictate
    /// 0...1 的实时音量(驱动波形动画)。
    private(set) var level: Float = 0
    /// 录音时的实时识别文本(已定稿部分 + 未定稿尾部)。
    private(set) var liveText = ""
    /// 上一次成功输入的文字(Passport"再次输入"动作使用)。
    private(set) var lastText: String?
    /// 当前是否为免提(短按开始)模式,界面据此显示 ✕ / ✓ 按钮。
    var isHandsFree: Bool { interpreter.isHandsFree }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engines: DictationEngineSource
    /// 润色 / 听写翻译。
    @ObservationIgnored private let postProcessor: DictationPostProcessing
    @ObservationIgnored private let inserter: TextInserting
    @ObservationIgnored private let sounds: SoundEffects
    @ObservationIgnored private let makeSource: () -> AudioSource

    @ObservationIgnored private var interpreter = PressInterpreter()
    @ObservationIgnored private var source: AudioSource?
    @ObservationIgnored private var sessionTask: Task<ASRSession?, Never>?
    @ObservationIgnored private var sessionReady = false
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var committedText: [String] = []
    /// 本次识别过程中收到的错误(云端识别网络 / 鉴权问题)。
    @ObservationIgnored private var streamError: String?
    @ObservationIgnored private var partialText = ""
    @ObservationIgnored private var target: NSRunningApplication?
    @ObservationIgnored private var targetPreparation: Task<Bool, Never>?
    @ObservationIgnored private var validateInsertion: (@MainActor () async throws -> Void)?
    @ObservationIgnored private var startedAt = Date()
    /// 仅 Passport 的 Codex 专用模式使用：录音起点绑定空输入框，识别完成后先粘贴，再由上键安全发送。
    @ObservationIgnored private var codexCoordinator: CodexActionCoordinator?
    @ObservationIgnored private var codexTargetTask: Task<CodexDraftTarget?, Never>?

    init(settings: AppSettings, engines: DictationEngineSource, postProcessor: DictationPostProcessing,
         inserter: TextInserting, sounds: SoundEffects, makeSource: @escaping () -> AudioSource) {
        self.settings = settings
        self.engines = engines
        self.postProcessor = postProcessor
        self.inserter = inserter
        self.sounds = sounds
        self.makeSource = makeSource
    }

    // MARK: - 触发入口

    /// 触发键按下(快捷键、Passport OK 键、胶囊按钮)。
    func pressDown(mode: Mode, style: PressInterpreter.Style = .hybrid, codex: CodexActionCoordinator? = nil,
                   prepareTarget: (@MainActor () async throws -> NSRunningApplication)? = nil,
                   validateInsertion: (@MainActor () async throws -> Void)? = nil,
                   at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch interpreter.down(at: time, style: style) {
        case .start: start(mode: mode, codex: codex, prepareTarget: prepareTarget, validateInsertion: validateInsertion)
        case .stop: stop()
        case .cancel: cancel()
        case .none: break
        }
    }

    /// 触发键松开。
    func pressUp(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch interpreter.up(at: time) {
        case .stop: stop()
        case .cancel: cancel()
        case .start, .none: break
        }
    }

    /// 点击胶囊上的麦克风:免提开始 / 结束。
    func toggle(mode: Mode = .dictate, codex: CodexActionCoordinator? = nil) {
        if phase == .recording || phase == .starting {
            stop()
        } else {
            pressDown(mode: mode, codex: codex)
            _ = interpreter.up()  // 立即松开 = 短按 = 免提
        }
    }

    // MARK: - 流程

    private func start(mode: Mode, codex: CodexActionCoordinator?,
                       prepareTarget: (@MainActor () async throws -> NSRunningApplication)?,
                       validateInsertion: (@MainActor () async throws -> Void)?) {
        guard !phase.isBusy else {
            // 上一次还在处理:这次按下不开始录音,也要把按键状态复位,
            // 否则 PressInterpreter 以为在录音,下一次按下会被当成"结束"吞掉。
            interpreter.reset()
            return
        }
        resetTask?.cancel()
        guard let engine = engines.dictationEngine(for: settings.dictationModelID) else {
            fail(.noModel)
            return
        }
        if mode == .translate, let reason = postProcessor.translationUnavailableReason {
            fail(.translationUnavailable(reason: reason))
            return
        }

        self.mode = mode
        self.validateInsertion = validateInsertion
        self.codexCoordinator = codex
        codexTargetTask = codex.map { coordinator in
            Task { [weak self] in
                let target = await coordinator.captureTarget()
                // 目标一开始就不可用时立即中止,不让用户继续对着不会发送的设备说话。
                if target == nil { self?.codexTargetCaptureFailed(coordinator) }
                return target
            }
        }
        target = NSWorkspace.shared.frontmostApplication
        targetPreparation?.cancel()
        targetPreparation = prepareTarget.map { prepare in
            Task { [weak self] in
                do {
                    let target = try await prepare()
                    guard !Task.isCancelled else { return false }
                    self?.target = target
                    return true
                } catch {
                    if !Task.isCancelled {
                        self?.cancel()
                        self?.fail(.other(error.localizedDescription))
                    }
                    return false
                }
            }
        }
        committedText = []
        streamError = nil
        partialText = ""
        liveText = ""
        sessionReady = false
        phase = .starting

        // 先开麦克风再准备会话,模型加载期间的声音缓存起来不丢。
        let buffer = SampleBuffer()
        let source = makeSource()
        source.onSamples = { [weak self] samples in
            buffer.append(samples)
            let level = AudioFormats.level(of: samples)
            Task { @MainActor in self?.updateLevel(level) }
        }
        do {
            try source.start()
        } catch {
            fail(.other(error.localizedDescription))
            return
        }
        self.source = source
        startedAt = Date()
        sounds.start()

        // 会话创建(可能需要加载模型)放进独立任务,stop() 会等待它的结果。
        let options = ASROptions(purpose: .dictation, language: settings.language, vocabulary: settings.vocabularyTerms)
        sessionTask = Task { [weak self] () -> ASRSession? in
            do {
                let session = try await engine.makeSession(options)
                // 等待期间被取消(✕):丢弃会话,不碰状态(此时可能已经开始了新的一次听写)。
                guard !Task.isCancelled, let self else { session.cancel(); return nil }
                buffer.attach(session)
                sessionReady = true
                if phase == .starting { phase = .recording }
                eventsTask = Task { [weak self] in
                    for await event in session.events { self?.handle(event) }
                }
                return session
            } catch {
                // 取消引起的错误(CancellationError 等)不是失败:cancel() 已经复位了状态,这里什么都不做。
                guard !Task.isCancelled, !(error is CancellationError) else { return nil }
                source.stop()
                self?.source = nil
                self?.fail(.other(error.localizedDescription))
                return nil
            }
        }
    }

    /// 结束录音并完成识别、后处理和输入。
    func stop() {
        guard phase == .recording || phase == .starting else { return }
        interpreter.reset()
        let source = self.source
        let mode = self.mode
        let codexCoordinator = self.codexCoordinator
        let codexTargetTask = self.codexTargetTask
        let targetPreparation = self.targetPreparation
        let duration = Date().timeIntervalSince(startedAt)
        phase = .processing(.recognizing)
        level = 0
        sounds.stop()

        let sessionTask = self.sessionTask
        // 每个 await 之后都检查取消:cancel() 已经把状态复位(甚至可能开始了新的一次听写),
        // 这里不能再改状态、粘贴或报错。
        flowTask = Task {
            // 松开后多录 150 ms,避免吃掉最后一个字。
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            source?.stop()
            self.source = nil
            if !sessionReady { phase = .processing(.loadingModel) }
            let session = await sessionTask?.value
            guard !Task.isCancelled else { return }
            guard let session else {
                if case .failed = phase { return }
                fail(.engineNotReady)
                return
            }
            phase = .processing(.recognizing)
            let started = Date()
            var text = await session.finish()
            // 会话结束时会关闭事件流:等事件任务把剩下的事件(如结束时才报告的超时错误)处理完。
            await self.eventsTask?.value
            guard !Task.isCancelled else { return }
            self.sessionTask = nil
            self.eventsTask = nil
            Log.dictation.info("ASR finished in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s for \(duration, format: .fixed(precision: 1))s audio")

            text = TranscriptText.normalize(text)
            guard !text.isEmpty else {
                // 误触(极短按压)静默结束,否则提示没听到。
                Log.dictation.info("empty transcript after \(duration, format: .fixed(precision: 1))s")
                if let streamError { fail(.other(streamError)) }
                else if duration < 0.5 { finishSilently() } else { fail(.noSpeech) }
                return
            }

            if let step = postProcessor.step(for: mode) { phase = .processing(step) }
            let processed = await postProcessor.process(text, mode: mode)
            guard !Task.isCancelled else { return }
            text = processed.text
            if let targetPreparation, !(await targetPreparation.value) { return }
            guard !Task.isCancelled else { return }
            let codexTarget: CodexDraftTarget?
            if let codexCoordinator {
                guard let target = await codexTargetTask?.value else {
                    self.fail(Self.codexFailure(codexCoordinator.captureFailure))
                    return
                }
                guard await codexCoordinator.validateForDraft(target) else {
                    self.fail(.codexTargetChanged)
                    return
                }
                codexTarget = target
            } else {
                codexTarget = nil
            }
            do { try await validateInsertion?() }
            catch {
                if !Task.isCancelled { fail(.codexTargetChanged) }
                return
            }
            guard !Task.isCancelled else { return }
            lastText = text
            let outcome = await inserter.insert(text, target: target)
            guard !Task.isCancelled else { return }
            Log.dictation.info("inserted \(text.count, privacy: .public) chars: \(String(describing: outcome), privacy: .public)")
            switch outcome {
            // 退回原文时用警告结果,不显示绿色「已输入」。只复制到剪贴板时优先说明复制原因(用户得自己粘贴)。
            case .pasted:
                if let codexCoordinator, let codexTarget {
                    guard await codexCoordinator.validatePastedDraft(codexTarget, text: text) else {
                        self.fail(.codexDraftNotConfirmed)
                        return
                    }
                    codexCoordinator.append(
                        text, target: codexTarget, expiresAt: Date().addingTimeInterval(5 * 60)
                    )
                    guard codexCoordinator.outcome == .ready else {
                        self.fail(.codexTargetChanged)
                        return
                    }
                    succeed(.draftReady(processed.warning))
                } else {
                    succeed(.typed(warning: processed.warning))
                }
            case .copied(let reason): succeed(.copied(reason))
            }
            self.clearCodexSession()
        }
    }

    /// 把上一次的文字再输入一次到当前焦点。
    func reinsertLast() {
        guard let lastText, !phase.isBusy else { return }
        Task { _ = await inserter.insert(lastText, target: NSWorkspace.shared.frontmostApplication) }
    }

    /// 放弃本次录音(✕ 按钮、Passport 长按下键)。
    func cancel() {
        guard phase.isBusy else { return }
        interpreter.reset()
        flowTask?.cancel()
        targetPreparation?.cancel()
        targetPreparation = nil
        flowTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        source?.stop()
        source = nil
        clearCodexSession(cancelCapture: true)
        if let task = sessionTask {
            task.cancel()
            Task { await task.value?.cancel() }
        }
        sessionTask = nil
        level = 0
        liveText = ""
        phase = .idle
    }

    // MARK: - 内部

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .final(let text):
            committedText.append(text)
            partialText = ""
        case .partial(let text):
            partialText = text
        case .failure(let message):
            // 记下识别错误(如云端鉴权失败);结束时如果没有得到文字,就把它作为失败原因显示。
            streamError = message
            return
        }
        liveText = TranscriptText.join(committedText + [partialText])
    }

    private func updateLevel(_ value: Float) {
        guard phase == .recording || phase == .starting else { return }
        // 上升快、下降慢,波形更有弹性。
        level = AudioFormats.smoothLevel(level, toward: value, decay: 0.75)
    }

    private func succeed(_ result: DictationResult) {
        clearCodexSession()
        phase = .done(result)
        // 警告结果(翻译 / 润色失败)多停留一会儿:用户要看清原因,也可能点击胶囊打开设置。
        scheduleReset(after: result.isWarning ? 4.0 : 1.2)
    }

    private func fail(_ failure: DictationFailure) {
        clearCodexSession(cancelCapture: true)
        interpreter.reset()
        phase = .failed(failure)
        sounds.error()
        // 与 Passport 固件的错误页停留时长(ERR_HOLD_MS)一致;可以点击去设置的失败多停留一会儿。
        if case .translationUnavailable = failure { scheduleReset(after: 4.0) } else { scheduleReset(after: 2.0) }
    }

    private func finishSilently() {
        phase = .idle
        liveText = ""
        clearCodexSession()
    }

    private func clearCodexSession(cancelCapture: Bool = false) {
        if cancelCapture { codexTargetTask?.cancel() }
        codexCoordinator = nil
        codexTargetTask = nil
    }

    private func codexTargetCaptureFailed(_ coordinator: CodexActionCoordinator) {
        guard codexCoordinator === coordinator, phase.isBusy, !Task.isCancelled else { return }
        fail(Self.codexFailure(coordinator.captureFailure))
    }

    private static func codexFailure(_ failure: CodexActionCoordinator.CaptureFailure?) -> DictationFailure {
        switch failure {
        case .accessibilityDenied: .codexAccessibilityDenied
        case .notRunning: .codexNotRunning
        case .background: .codexBackground
        case .locked: .codexLocked
        case .inputNotEmpty: .codexInputNotEmpty
        case .running: .codexRunning
        case .approvalPending: .codexApprovalPending
        case .unavailable, .none: .codexTargetUnavailable
        }
    }

    private func scheduleReset(after seconds: Double) {
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if !phase.isBusy {
                phase = .idle
                liveText = ""
            }
        }
    }
}

/// 会话创建前先缓存音频,会话就绪后一次性送入,之后直接转发。
nonisolated final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var session: ASRSession?

    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            session.feed(samples)
        } else {
            pending.append(contentsOf: samples)
        }
    }

    func attach(_ session: ASRSession) {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { session.feed(pending) }
        pending = []
        self.session = session
    }
}

#if DEBUG
extension DictationController {
    /// 调试:直接停在完成卡片上(IB_PILL_RESULT),不录音、不自动复位,用于检查状态条排版。
    func debugShowResult(_ result: DictationResult) {
        phase = .done(result)
    }
}
#endif
