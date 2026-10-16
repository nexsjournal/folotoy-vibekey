import AppKit

/// 实时字幕:采集所选应用的声音 → 识别 → (可选)LLM 翻译 → 交给字幕条显示。
/// 本类只维护字幕数据,显示由状态条(PillView 的字幕条形态)负责。
@MainActor @Observable
final class SubtitleController {
    /// 一行字幕:原文 + 译文(译文异步到达)。
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var translation: String?
    }

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private(set) var appName = ""
    private(set) var appBundleID = ""
    /// 已定稿的字幕行(只保留最近几行)。
    private(set) var lines: [Line] = []
    /// 正在说的那句(未定稿,会不断变化)。
    private(set) var partial = ""
    private(set) var level: Float = 0
    /// 识别出错(如云端鉴权失败、网络中断)时的原因,收到新文字后清除。
    private(set) var streamError: String?
    /// 长时间收不到声音时提示检查系统音频录制权限。
    private(set) var silentTooLong = false

    var isRunning: Bool { status == .running || status == .starting }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let engines: EngineRegistry
    @ObservationIgnored private let processor: TextProcessor
    @ObservationIgnored private var tap: AppAudioTap?
    @ObservationIgnored private var session: ASRSession?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
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
        lines = []
        partial = ""
        streamError = nil
        silentTooLong = false
        status = .starting

        let modelID = settings.effectiveSubtitleModelID
        guard models.isInstalled(modelID), let engine = engines.engine(for: modelID) else {
            status = .failed(String(localized: "字幕模型未下载", bundle: .l10n))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let options = ASROptions(purpose: .subtitles, language: settings.language, vocabulary: settings.vocabularyTerms)
                let session = try await engine.makeSession(options)
                guard status == .starting else { session.cancel(); return }
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
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// 听写进行中暂停解码(音频照常送入会话缓存),结束后恢复并补上积压的字幕。
    func setDecodingPaused(_ paused: Bool) {
        session?.setDecodingPaused(paused)
    }

    func stop() {
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
            let line = Line(text: text)
            lines.append(line)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            if settings.subtitleTranslate { translate(line) }
        }
    }

    private func translate(_ line: Line) {
        guard processor.isAvailable else { return }
        let context = lines.dropLast().suffix(3).map(\.text)
        Task {
            guard let translation = try? await processor.translateSubtitle(line.text, context: Array(context)) else { return }
            if let index = lines.firstIndex(where: { $0.id == line.id }) {
                lines[index].translation = translation
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
