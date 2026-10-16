import AppKit

/// 实时字幕:采集所选应用的声音 → 识别 → (可选)LLM 翻译 → 交给字幕条显示。
/// 本类只维护字幕数据,显示由状态条(PillView 的字幕条形态)和字幕记录窗口负责。
@MainActor @Observable
final class SubtitleController {
    /// 一行字幕:原文 + 译文(译文异步到达)。
    typealias Line = CaptionTranscript.Entry

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private(set) var appName = ""
    private(set) var appBundleID = ""
    /// 本次(或上一次)字幕会话的完整记录。停止后保留,直到下一次开始,供记录窗口查看和保存。
    private(set) var transcript = CaptionTranscript()
    /// 字幕条显示的最近几行定稿。
    var lines: [Line] { Array(transcript.entries.suffix(maxLines)) }
    /// 正在说的那句(未定稿,会不断变化)。
    private(set) var partial = ""
    private(set) var level: Float = 0
    /// 识别出错(如云端鉴权失败、网络中断)时的原因,收到新文字后清除。
    private(set) var streamError: String?
    /// 长时间收不到声音时提示检查系统音频录制权限。
    private(set) var silentTooLong = false

    var isRunning: Bool { status == .running || status == .starting }

    /// 字幕条是否要显示:运行中,或者启动失败(显示原因,用户点结束后消失)。
    var needsSurface: Bool {
        if case .failed = status { return true }
        return isRunning
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let engines: EngineRegistry
    @ObservationIgnored private let processor: TextProcessor
    @ObservationIgnored private var tap: AppAudioTap?
    @ObservationIgnored private var session: ASRSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    /// 正在进行的启动(加载模型、连接云端、建立音频采集)。
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// 每次 start / stop 递增。启动任务只在代数没变时才安装采集和会话,
    /// 避免"上一次启动还没完成就开始下一次"时两次启动都装上、旧的再也停不掉。
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastSoundAt = Date()

    private let maxLines = 3

    init(settings: AppSettings, models: ModelManager, engines: EngineRegistry, processor: TextProcessor) {
        self.settings = settings
        self.models = models
        self.engines = engines
        self.processor = processor
    }

    /// 开始转录某个应用的声音。
    func start(app: AudioApp) {
        stop()
        appName = app.name
        appBundleID = app.bundleID
        transcript = CaptionTranscript(appName: app.name)
        partial = ""
        streamError = nil
        silentTooLong = false
        status = .starting

        let modelID = settings.effectiveSubtitleModelID
        guard models.isInstalled(modelID), let engine = engines.engine(for: modelID) else {
            status = .failed(models.unavailableMessage(modelID))
            return
        }
        let current = generation
        startTask = Task { [weak self] in
            guard let self else { return }
            var pendingSession: ASRSession?
            do {
                let options = ASROptions(purpose: .subtitles, language: settings.language, vocabulary: settings.vocabularyTerms)
                let session = try await engine.makeSession(options)
                pendingSession = session
                // 等待期间用户已经停止或重新开始了:丢弃这次的会话。
                guard generation == current, status == .starting else { session.cancel(); return }
                let tap = AppAudioTap(bundleID: app.bundleID)
                tap.onSamples = { [weak self] samples in
                    session.feed(samples)
                    let level = AudioFormats.level(of: samples)
                    Task { @MainActor in self?.updateLevel(level) }
                }
                try tap.start()
                self.tap = tap
                self.session = session
                status = .running
                lastSoundAt = Date()
                eventsTask = Task { [weak self] in
                    for await event in session.events { self?.handle(event) }
                }
                watchSilence()
                Log.subtitles.info("subtitles started for \(app.bundleID, privacy: .public)")
            } catch {
                // 采集启动失败(如没有系统音频录制权限)时,已建立的识别会话(云端连接)也要关掉。
                pendingSession?.cancel()
                guard generation == current else { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// 听写进行中暂停解码(音频照常送入会话缓存),结束后恢复并补上积压的字幕。
    func setDecodingPaused(_ paused: Bool) {
        session?.setDecodingPaused(paused)
    }

    /// 停止采集和识别。正在说的半句会作为最后一句记入记录,不丢内容。
    func stop() {
        let wasRunning = isRunning
        generation += 1
        startTask?.cancel()
        startTask = nil
        if !partial.isEmpty { transcript.append(Line(text: partial)) }
        if wasRunning { transcript.endedAt = Date() }
        tap?.stop()
        tap = nil
        session?.cancel()
        session = nil
        eventsTask?.cancel()
        silenceTask?.cancel()
        level = 0
        partial = ""
        if status != .stopped { status = .stopped }
    }

    /// 记录已保存到第 `count` 句(之后没有新内容就不再提示保存)。只有仍是同一次会话时才标记;
    /// 保存面板打开期间新到的句子不算已保存。
    func markTranscriptSaved(_ saved: CaptionTranscript) {
        if transcript.id == saved.id { transcript.markSaved(upTo: saved.entries.count) }
    }

    /// 运行中打开翻译:补译最新一句,字幕条马上有原文 + 译文可显示(之前的句子不补,避免一次发出大量请求)。
    func translationEnabled() {
        guard isRunning, let last = transcript.entries.last, !last.translationSettled else { return }
        translate(last)
    }

    #if DEBUG
    /// 仅调试:填入示例记录并显示为运行中(不采集音频),用于检查字幕条和记录窗口的排版。
    func debugShow(_ sample: CaptionTranscript, partial: String) {
        stop()
        transcript = sample
        appName = sample.appName
        self.partial = partial
        status = .running
    }
    #endif

    // MARK: - 内部

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .failure(let message):
            streamError = message
        case .partial(let text):
            partial = TranscriptText.normalize(text)
            if !text.isEmpty { streamError = nil }
        case .final(let raw):
            streamError = nil
            let text = TranscriptText.normalize(raw)
            partial = ""
            guard !text.isEmpty else { return }
            let line = Line(text: text)
            transcript.append(line)
            if settings.subtitleTranslate { translate(line) }
        }
    }

    private func translate(_ line: Line) {
        guard processor.isAvailable else { return }
        // 上下文:当前句之前的 3 句原文和已有译文。
        let context = transcript.entries.prefix { $0.id != line.id }.suffix(3).map { (source: $0.text, translation: $0.translation) }
        Task {
            do {
                let translation = try await processor.translateSubtitle(line.text, context: Array(context))
                transcript.setTranslation(translation, for: line.id)
            } catch {
                // 标记失败,字幕条不再一直显示"翻译中"。
                transcript.setTranslationFailed(for: line.id)
                Log.subtitles.error("subtitle translation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateLevel(_ value: Float) {
        level = AudioFormats.smoothLevel(level, toward: value)
        if value > 0.05 {
            lastSoundAt = Date()
            silentTooLong = false
        }
    }

    /// 运行 15 秒仍完全没有声音时提示(通常是没有授予系统音频录制权限,或应用确实没在播放)。
    private func watchSilence() {
        silenceTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if status == .running, Date().timeIntervalSince(lastSoundAt) > 15 { silentTooLong = true }
            }
        }
    }
}
