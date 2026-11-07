import AppKit

/// 实时字幕:采集所选应用的声音 → 识别 → 按句记入字幕记录并翻译(设置里选的一种翻译方式)。
/// 字幕条的逐句显示由 `feed`(CaptionFeed)负责;本类只维护会话和记录,显示由状态条和字幕记录窗口负责。
/// 翻译开关只对这一场字幕有效(`translationEnabled`,每场开始时关闭),只能在字幕条「译」菜单里打开(以及 Passport 上键)。
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
    /// 正在说、还没定稿的一段(文字会不断变化)。开始时间在这段第一次出现识别结果时记下,定稿后沿用,
    /// 字幕记录窗口里这一行因此一出现就带时间、定稿后原位变色。
    private(set) var live: CaptionTranscript.Live?
    /// 字幕条的逐句数据源。
    let feed: CaptionFeed
    private(set) var level: Float = 0
    /// 识别出错(如云端鉴权失败、网络中断)时的原因,收到新文字后清除。
    private(set) var streamError: String?
    /// 长时间收不到声音时提示检查系统音频录制权限。
    private(set) var silentTooLong = false
    /// 本场字幕是否翻译(不持久化:每场新的字幕默认不翻译)。
    private(set) var translationEnabled = false

    var isRunning: Bool { status == .running || status == .starting }

    /// 字幕条是否要显示:运行中,或者启动失败(显示原因,用户点结束后消失)。
    var needsSurface: Bool {
        if case .failed = status { return true }
        return isRunning
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let engines: EngineRegistry
    @ObservationIgnored private let translation: TranslationService
    /// 整句译文的去重 / 合并入口(字幕条和字幕记录共用)。
    @ObservationIgnored private let sentences: SentenceTranslator
    /// 换翻译设置时递增,旧设置下发出的翻译结果不再写入记录。
    @ObservationIgnored private var translationGeneration = 0
    /// 最近一次(重新)翻译时用的目标语言和方式:字幕条「译」菜单选语言会先写设置再开翻译,设置监听随后又通知一次,
    /// 用它判断设置其实没变、不重复翻译同一句。
    @ObservationIgnored private var appliedTranslation: (target: TargetLanguage, method: TranslationMethod)?
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

    init(settings: AppSettings, models: ModelManager, engines: EngineRegistry, translation: TranslationService) {
        self.settings = settings
        self.models = models
        self.engines = engines
        self.translation = translation
        sentences = SentenceTranslator(service: translation)
        feed = CaptionFeed(settings: settings, translation: translation, sentences: sentences)
    }

    /// 开始转录某个应用的声音。
    func start(app: AudioApp) {
        stop()
        appName = app.name
        appBundleID = app.bundleID
        transcript = CaptionTranscript(appName: app.name)
        live = nil
        streamError = nil
        silentTooLong = false
        translationEnabled = false
        translationGeneration += 1
        appliedTranslation = nil
        sentences.reset()
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
                feed.start()
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
        if let live { transcript.commit([live.text], startedAt: live.startedAt) }
        if wasRunning { transcript.endedAt = Date() }
        tap?.stop()
        tap = nil
        session?.cancel()
        session = nil
        eventsTask?.cancel()
        silenceTask?.cancel()
        feed.reset()
        translationEnabled = false
        level = 0
        live = nil
        if status != .stopped { status = .stopped }
    }

    /// 记录已保存到第 `count` 句(之后没有新内容就不再提示保存)。只有仍是同一次会话时才标记;
    /// 保存面板打开期间新到的句子不算已保存。
    func markTranscriptSaved(_ saved: CaptionTranscript) {
        if transcript.id == saved.id { transcript.markSaved(upTo: saved.entries.count) }
    }

    /// 打开 / 关闭本场字幕的翻译(字幕条「译」菜单、Passport 上键)。
    /// 打开时从最新一句开始翻译,之前的句子不补(需要时在字幕记录窗口里一次翻译)。
    func setTranslationEnabled(_ enabled: Bool) {
        guard enabled != translationEnabled else { return }
        translationEnabled = enabled
        translationGeneration += 1
        feed.setTranslationEnabled(enabled)
        if enabled { translateLatest() }
    }

    func toggleTranslation() {
        setTranslationEnabled(!translationEnabled)
    }

    /// 换了目标语言或翻译方式(AppState 监听设置):翻译中的话,按新设置重新翻译最新一句。
    /// 设置和上次翻译时相同(例如「译」菜单选语言时先写了设置再开翻译)就什么都不做,避免同一句翻两次。
    func translationConfigChanged() {
        guard translationEnabled else { return }
        if let applied = appliedTranslation, applied.target == settings.subtitleTarget, applied.method == settings.subtitleTranslationMethod {
            return
        }
        translationGeneration += 1
        sentences.reset()
        feed.restartTranslation()
        translateLatest()
    }

    /// 字幕记录窗口批量翻译 / AI 润色的结果写回记录。只有仍是同一场字幕时才写(期间可能开始了新的一场)。
    func applyTranslations(_ translations: [UUID: String], failed: Set<UUID> = [], target: TargetLanguage,
                           polished: Bool = false, session: UUID) {
        guard transcript.id == session else { return }
        transcript.setTranslations(translations, failed: failed, target: target, polished: polished)
    }

    /// 重新翻译最新一句,字幕条马上有对应的译文。
    private func translateLatest() {
        appliedTranslation = (settings.subtitleTarget, settings.subtitleTranslationMethod)
        guard isRunning, translationEnabled, let last = transcript.entries.last else { return }
        transcript.clearTranslation(for: last.id)
        translate([last])
    }

    #if DEBUG
    /// 仅调试:填入示例记录并显示为运行中(不采集音频),用于检查字幕条和记录窗口的排版。
    func debugShow(_ sample: CaptionTranscript, partial: String) {
        stop()
        transcript = sample
        appName = sample.appName
        live = partial.isEmpty ? nil : CaptionTranscript.Live(startedAt: Date(), text: partial)
        status = .running
        translationEnabled = true
        feed.debugShow(sample.entries.map { (source: $0.text, translation: $0.translation) }, live: partial,
                       pendingDraft: "我们有一些益智游戏", liveTranslation: "约束，约束")
    }
    #endif

    // MARK: - 内部

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .failure(let message):
            streamError = message
        case .partial(let raw):
            let text = TranscriptText.normalize(raw)
            // 同一段话沿用第一次出现文字时的开始时间;文字清空(引擎定稿后 / 判定为噪音)时这段结束。
            live = text.isEmpty ? nil : CaptionTranscript.Live(startedAt: live?.startedAt ?? Date(), text: text)
            if !raw.isEmpty { streamError = nil }
            feed.partial(text)
        case .final(let raw):
            streamError = nil
            var text = TranscriptText.normalize(raw)
            let startedAt = live?.startedAt
            live = nil
            if text.isEmpty {
                // 引擎给了空定稿(判定这段只有噪音),但识别中已经连续两次确认过的文字是真内容:
                // 不能连同已经显示 / 翻译过的暂定内容一起丢掉,把它当作这段的定稿。
                text = feed.pendingConfirmed
                guard !text.isEmpty else {
                    feed.final(text: "", entries: [])
                    return
                }
            }
            // 按句记入记录(一次定稿常常有好几句):每句单独翻译,字幕条也按句显示。
            let sentences = SentenceSplitter.split(text, final: true).complete
            Log.subtitles.debug("final \(text.count) chars, \(sentences.count) sentences")
            let lines = transcript.commit(sentences, startedAt: startedAt)
            feed.final(text: text, entries: lines.map { (text: $0.text, entryID: $0.id) })
            if translationEnabled { translate(lines) }
        }
    }

    /// 翻译记录里的句子(按当前的目标语言和翻译方式):
    /// - AI:同一批句子**依次**带上下文流式翻译(后一句的上下文里才有前一句的译文;也不会一次开出多路流式请求),
    ///   逐字生成的译文同步到字幕条(记录路径);
    /// - 系统翻译 / 在线服务:经 SentenceTranslator,与字幕条的同一句共享结果,不重复请求。
    /// 方式不可用时不在这里拦:TranslationService 会给出 `.failed(原因)`,字幕条和记录都能看到原因。
    private func translate(_ lines: [Line]) {
        let target = settings.subtitleTarget, method = settings.subtitleTranslationMethod
        let sessionID = transcript.id, generation = translationGeneration
        let isCurrent = { [weak self] in self?.transcript.id == sessionID && self?.translationGeneration == generation }
        if method.isLLM {
            Task {
                for line in lines {
                    guard isCurrent() else { return }
                    // 上下文:当前句之前的 3 句原文和已有译文(前一句刚翻完,这里就能拿到它的译文)。
                    let context = transcript.entries.prefix { $0.id != line.id }.suffix(3).map { (source: $0.text, translation: $0.translation) }
                    for await update in translation.translateLine(line.text, context: Array(context), target: target, method: method) {
                        guard isCurrent() else { return }
                        feed.entryTranslation(line.id, update)
                        switch update {
                        case .streaming(let text): transcript.setTranslation(text, for: line.id, target: target)
                        case .final(let text): transcript.setTranslation(text, for: line.id, target: target)
                        case .sameLanguage: transcript.setTranslation("", for: line.id, target: target)
                        case .failed(let reason):
                            transcript.setTranslationFailed(for: line.id)
                            Log.subtitles.error("subtitle translation failed: \(reason, privacy: .public)")
                        }
                    }
                }
            }
            return
        }
        for line in lines {
            Task {
                let result = await sentences.translate(line.text, target: target, method: method)
                guard isCurrent() else { return }
                switch result {
                case .translated(let text): transcript.setTranslation(text, for: line.id, target: target)
                case .sameLanguage: transcript.setTranslation("", for: line.id, target: target)
                case .cancelled: break
                case .failed(let reason):
                    transcript.setTranslationFailed(for: line.id)
                    Log.subtitles.error("subtitle translation failed: \(reason, privacy: .public)")
                }
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
