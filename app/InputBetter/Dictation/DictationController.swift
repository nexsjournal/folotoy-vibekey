import AppKit

/// 听写流程的状态机:录音 → 识别 → (润色 / 翻译)→ 输入。
/// 只负责编排,具体能力通过注入的依赖完成:
/// - `makeSource`:按设置创建音源(系统麦克风或 Passport);
/// - `engines` / `models`:识别引擎与模型状态;
/// - `processor`:LLM 后处理;`inserter`:把文本输入到焦点窗口。
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
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let engines: EngineRegistry
    @ObservationIgnored private let processor: TextProcessor
    /// 听写翻译(LLM 或系统翻译)。
    @ObservationIgnored private let translation: TranslationService
    @ObservationIgnored private let inserter: TextInserter
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
    @ObservationIgnored private var startedAt = Date()

    init(settings: AppSettings, models: ModelManager, engines: EngineRegistry, processor: TextProcessor,
         translation: TranslationService,
         inserter: TextInserter, sounds: SoundEffects, makeSource: @escaping () -> AudioSource) {
        self.translation = translation
        self.settings = settings
        self.models = models
        self.engines = engines
        self.processor = processor
        self.inserter = inserter
        self.sounds = sounds
        self.makeSource = makeSource
    }

    // MARK: - 触发入口

    /// 触发键按下(快捷键、Passport OK 键、胶囊按钮)。
    func pressDown(mode: Mode) {
        switch interpreter.down() {
        case .start: start(mode: mode)
        case .stop: stop()
        case .none: break
        }
    }

    /// 触发键松开。
    func pressUp() {
        if interpreter.up() == .stop { stop() }
    }

    /// 点击胶囊上的麦克风:免提开始 / 结束。
    func toggle(mode: Mode = .dictate) {
        if phase == .recording || phase == .starting {
            stop()
        } else {
            pressDown(mode: mode)
            _ = interpreter.up(at: Date())  // 立即松开 = 短按 = 免提
        }
    }

    // MARK: - 流程

    private func start(mode: Mode) {
        guard !phase.isBusy else { return }
        resetTask?.cancel()
        let modelID = settings.dictationModelID
        guard models.isInstalled(modelID), let engine = engines.engine(for: modelID) else {
            fail(.noModel)
            return
        }
        if mode == .translate, !translation.canTranslateDictation {
            fail(.translationUnavailable)
            return
        }

        self.mode = mode
        target = NSWorkspace.shared.frontmostApplication
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
                guard !Task.isCancelled else { session.cancel(); return nil }
                buffer.attach(session)
                self?.sessionReady = true
                if let self, self.phase == .starting { self.phase = .recording }
                self?.eventsTask = Task { [weak self] in
                    for await event in session.events { self?.handle(event) }
                }
                return session
            } catch {
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
        let duration = Date().timeIntervalSince(startedAt)
        phase = .processing(.recognizing)
        level = 0
        sounds.stop()

        flowTask = Task {
            // 松开后多录 150 ms,避免吃掉最后一个字。
            try? await Task.sleep(for: .milliseconds(150))
            source?.stop()
            self.source = nil
            if !sessionReady { phase = .processing(.loadingModel) }
            guard let session = await sessionTask?.value else {
                if case .failed = phase { return }
                fail(.engineNotReady)
                return
            }
            phase = .processing(.recognizing)
            let started = Date()
            var text = await session.finish()
            eventsTask?.cancel()
            sessionTask = nil
            Log.dictation.info("ASR finished in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s for \(duration, format: .fixed(precision: 1))s audio")

            text = TranscriptText.normalize(text)
            guard !text.isEmpty else {
                // 误触(极短按压)静默结束,否则提示没听到。
                Log.dictation.info("empty transcript after \(duration, format: .fixed(precision: 1))s")
                if let streamError { fail(.other(streamError)) }
                else if duration < 0.5 { finishSilently() } else { fail(.noSpeech) }
                return
            }

            text = await postProcess(text, mode: mode)
            lastText = text
            let outcome = await inserter.insert(text, target: target)
            Log.dictation.info("inserted \(text.count, privacy: .public) chars: \(String(describing: outcome), privacy: .public)")
            switch outcome {
            case .pasted: succeed(.typed)
            case .copied(let reason): succeed(.copied(reason))
            }
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
        eventsTask?.cancel()
        source?.stop()
        source = nil
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

    private func postProcess(_ text: String, mode: Mode) async -> String {
        do {
            switch mode {
            case .translate:
                phase = .processing(.translating)
                return try await translation.translateDictation(text)
            case .dictate where settings.polishEnabled && processor.isAvailable:
                phase = .processing(.polishing)
                return try await processor.polish(text)
            default:
                return text
            }
        } catch {
            // LLM 失败时退回原文,不丢用户说的话。
            Log.llm.error("post-process failed: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

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
        phase = .done(result)
        scheduleReset(after: 1.2)
    }

    private func fail(_ failure: DictationFailure) {
        interpreter.reset()
        phase = .failed(failure)
        sounds.error()
        scheduleReset(after: 2.4)
    }

    private func finishSilently() {
        phase = .idle
        liveText = ""
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
