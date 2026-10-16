import Foundation

/// 字幕记录的分段总结:AI 每隔一段时间总结一次这段时间的新内容。
///
/// 只在"字幕记录窗口开着 + 停在「总结」页 + 开关打开"时工作(`isActive`);任一条件不满足立即暂停,
/// 正在进行的请求一并取消(这段内容留到下次再总结,不浪费额度)。
/// 调用链:TranscriptView(总结页出现 / 消失)→ setTabVisible;WindowManager(窗口打开 / 关闭)→ setWindowVisible;
///   定时检查(每 5 秒)→ 满足间隔且新内容足够 → summarize → LLMClient.stream(边生成边显示)→ sections。
/// 总结只存在内存里,跟着字幕会话走:开始新的字幕会话时清空。
@MainActor @Observable
final class TranscriptSummarizer {
    /// 一段总结。
    struct Section: Identifiable, Equatable {
        let id = UUID()
        /// 覆盖的时间范围,如 "00:02:10 – 00:04:30"。
        let range: String
        var text: String
        var generating: Bool
    }

    private(set) var sections: [Section] = []
    /// 最近一次失败的原因(下一次成功后清除)。
    private(set) var error: String?
    /// 是否正在生成。
    var isGenerating: Bool { task != nil }
    /// 窗口开着、停在总结页、开关打开。
    var isActive: Bool { windowVisible && tabVisible && settings.summaryEnabled }
    /// 能否总结(配置了可用的 LLM)。
    var isConfigured: Bool { settings.summaryLLMConfig != nil }
    /// 还没总结的句数。
    var pendingCount: Int { pendingEntries.count }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let subtitles: SubtitleController
    private var windowVisible = false
    private var tabVisible = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// 已总结到哪一句(记录里的句子 ID)和所属会话。
    @ObservationIgnored private var summarizedThrough: UUID?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var lastSummaryAt = Date.distantPast

    /// 至少有这么多新句子才自动总结(太短的内容总结没有意义)。
    static let minimumSentences = 4
    /// 一次最多送给 AI 的字符数(超过时取最近的部分)。
    static let maxCharacters = 8_000

    init(settings: AppSettings, subtitles: SubtitleController) {
        self.settings = settings
        self.subtitles = subtitles
    }

    // MARK: - 可见性(决定是否工作)

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        update()
    }

    func setTabVisible(_ visible: Bool) {
        tabVisible = visible
        update()
    }

    /// 开关、窗口或标签页变化后调用:满足条件就开始定时检查,否则暂停并取消进行中的请求。
    func update() {
        resetIfNewSession()
        if isActive {
            guard ticker == nil else { return }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
            cancelGeneration()
        }
    }

    /// 立即总结(不管间隔,有新内容就总结)。
    func summarizeNow() {
        resetIfNewSession()
        guard task == nil, !pendingEntries.isEmpty else { return }
        summarize()
    }

    /// 拷贝用的全部总结文字。
    var plainText: String {
        sections.filter { !$0.generating }.map { "[\($0.range)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: - 内部

    private var pendingEntries: [CaptionTranscript.Entry] {
        let entries = subtitles.transcript.entries
        guard let summarizedThrough, let index = entries.firstIndex(where: { $0.id == summarizedThrough }) else { return entries }
        return Array(entries[(index + 1)...])
    }

    private func tick() {
        resetIfNewSession()
        guard isActive, task == nil, isConfigured else { return }
        let interval = TimeInterval(max(1, settings.summaryInterval) * 60)
        let pending = pendingEntries
        // 到了间隔且新内容够多;字幕已经结束时把剩下的也总结掉。
        let enough = pending.count >= Self.minimumSentences || (!subtitles.isRunning && !pending.isEmpty)
        guard enough, Date().timeIntervalSince(lastSummaryAt) >= interval || !subtitles.isRunning else { return }
        summarize()
    }

    private func summarize() {
        guard let config = settings.summaryLLMConfig else {
            error = String(localized: "请先在 设置 › AI 润色与翻译 中配置服务", bundle: .l10n)
            return
        }
        let transcript = subtitles.transcript
        let pending = pendingEntries
        guard let first = pending.first, let last = pending.last else { return }
        var text = pending.map(\.text).joined(separator: "\n")
        if text.count > Self.maxCharacters { text = String(text.suffix(Self.maxCharacters)) }
        let previous = sections.last { !$0.generating }?.text
        let section = Section(range: "\(transcript.offset(of: first)) – \(transcript.offset(of: last))", text: "", generating: true)
        sections.append(section)
        error = nil
        let client = LLMClient(config: config)
        let language = TargetLanguage.autoPair().primary
        task = Task { [weak self] in
            await self?.run(client: client, language: language, text: text, previous: previous,
                            sectionID: section.id, lastEntryID: last.id)
        }
    }

    /// 生成一段总结(边生成边显示)。被取消时什么都不改(暂停时已经清理)。
    private func run(client: LLMClient, language: TargetLanguage, text: String, previous: String?,
                     sectionID: UUID, lastEntryID: UUID) async {
        var latest = ""
        do {
            for try await partial in client.stream(system: Prompts.summarize(language: language),
                                                   user: Prompts.summaryUser(transcript: text, previous: previous)) {
                guard !Task.isCancelled else { return }
                latest = partial
                setText(partial, for: sectionID, generating: true)
            }
            guard !Task.isCancelled else { return }
            setText(latest, for: sectionID, generating: false)
            summarizedThrough = lastEntryID
        } catch {
            guard !Task.isCancelled else { return }
            sections.removeAll { $0.id == sectionID }
            self.error = error.localizedDescription
        }
        // 成功或失败都等一个间隔再自动总结,避免连续请求。
        lastSummaryAt = Date()
        task = nil
    }

    private func setText(_ text: String, for id: UUID, generating: Bool) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[index].text = text
        sections[index].generating = generating
    }

    /// 暂停:取消进行中的请求,去掉没生成完的那段(内容留到下次总结)。
    private func cancelGeneration() {
        task?.cancel()
        task = nil
        sections.removeAll(where: \.generating)
    }

    /// 开始了新的字幕会话:清空上一场的总结。
    private func resetIfNewSession() {
        let current = subtitles.transcript.id
        guard sessionID != current else { return }
        sessionID = current
        cancelGeneration()
        sections = []
        error = nil
        summarizedThrough = nil
        lastSummaryAt = .distantPast
    }
}
