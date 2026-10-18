import Foundation

/// 字幕记录的分段总结:AI 每隔一段时间总结一次这段时间的新内容。
///
/// 只在"字幕记录窗口开着 + 停在「总结」页 + 开关打开(每场字幕默认关闭)"时工作(`isActive`);任一条件不满足立即暂停,
/// 正在进行的请求一并取消(这段内容留到下次再总结,不浪费额度)。
/// 调用链:TranscriptView(总结页出现 / 消失)→ setTabVisible;WindowManager(窗口打开 / 关闭)→ setWindowVisible;
///   定时检查(每 5 秒)→ 满足间隔且新内容足够 → summarize → LLMClient.stream(边生成边显示)→ sections。
/// 全文总结(`summarizeAll`):用户主动要求的一次性任务(结束字幕时勾选,或点「总结全文」),
///   不受上面的暂停规则影响;很长时先分块整理要点再汇总(map-reduce),避免超出模型输入长度。
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
    /// 全文总结(没有生成过为 nil)。
    private(set) var fullSummary: Section?
    /// 是否正在生成全文总结。
    var isSummarizingAll: Bool { fullTask != nil }
    /// 最近一次失败的原因(下一次成功后清除)。
    private(set) var error: String?
    /// 是否正在生成。
    var isGenerating: Bool { task != nil }
    /// 「自动总结」开关:只对当前这场字幕有效,每场新的字幕默认关闭。
    var enabled = false {
        didSet {
            // 打开后第一次总结也等满一个间隔(底部倒计时从这里开始)。
            if enabled, !oldValue { lastSummaryAt = Date() }
            update()
        }
    }
    /// 窗口开着、停在总结页、开关打开。
    var isActive: Bool { windowVisible && tabVisible && enabled }
    /// 能否总结(配置了可用的 LLM)。
    var isConfigured: Bool { settings.summaryLLMConfig != nil }
    /// 这场字幕还没有任何内容。
    var transcriptIsEmpty: Bool { subtitles.transcript.isEmpty }
    /// 还没总结的句数。
    var pendingCount: Int { pendingEntries.count }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let subtitles: SubtitleController
    private var windowVisible = false
    private var tabVisible = false
    private var task: Task<Void, Never>?
    private var fullTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// 已总结到哪一句(记录里的句子 ID)和所属会话。
    @ObservationIgnored private var summarizedThrough: UUID?
    @ObservationIgnored private var sessionID: UUID?
    /// 上次总结(或打开开关)的时间,下次自动总结从这里算起。
    private var lastSummaryAt = Date.distantPast

    /// 下次自动总结的时间(自动总结在工作时才有;到点后还要新内容至少 4 句)。
    var nextSummaryAt: Date? {
        guard isActive, isConfigured, !isGenerating, lastSummaryAt != .distantPast else { return nil }
        return lastSummaryAt.addingTimeInterval(TimeInterval(max(1, settings.summaryInterval) * 60))
    }

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
    /// 拷贝 / 保存用的全部总结文字:全文总结在前,分段总结在后。
    var plainText: String {
        var parts: [String] = []
        if let fullSummary, !fullSummary.generating {
            parts.append(String(localized: "全文总结（\(fullSummary.range)）", bundle: .l10n) + "\n" + fullSummary.text)
        }
        parts += sections.filter { !$0.generating }.map { "[\($0.range)]\n\($0.text)" }
        return parts.joined(separator: "\n\n")
    }

    /// 总结全文。已经在生成时忽略。
    func summarizeAll() {
        resetIfNewSession()
        guard fullTask == nil else { return }
        guard let config = settings.summaryLLMConfig else {
            error = String(localized: "请先在 设置 › AI 服务 中配置", bundle: .l10n)
            return
        }
        let transcript = subtitles.transcript
        guard let first = transcript.entries.first, let last = transcript.entries.last else { return }
        let range = "\(startOffset(before: first, in: transcript)) – \(transcript.offset(of: last))"
        fullSummary = Section(range: range, text: "", generating: true)
        error = nil
        let text = transcript.entries.map(\.text).joined(separator: "\n")
        let client = LLMClient(config: config)
        let language = TargetLanguage.autoPair().primary
        fullTask = Task { [weak self] in
            await self?.runAll(client: client, language: language, text: text)
        }
    }

    /// 一块最多送给 AI 的字符数;全文超过时分块整理要点再汇总。
    static let fullChunk = 12_000

    private func runAll(client: LLMClient, language: TargetLanguage, text: String) async {
        do {
            var input = text
            let chunks = Self.chunks(text, size: Self.fullChunk)
            if chunks.count > 1 {
                var notes: [String] = []
                for (index, chunk) in chunks.enumerated() {
                    guard !Task.isCancelled else { return }
                    fullSummary?.text = String(localized: "正在整理第 \(index + 1)/\(chunks.count) 部分…", bundle: .l10n)
                    notes.append(try await client.complete(system: Prompts.summaryNotes(language: language), user: chunk))
                }
                input = notes.joined(separator: "\n\n")
            }
            var latest = ""
            for try await partial in client.stream(system: Prompts.summarizeAll(language: language), user: input) {
                guard !Task.isCancelled else { return }
                latest = partial
                fullSummary?.text = partial
            }
            guard !Task.isCancelled else { return }
            fullSummary?.text = latest
            fullSummary?.generating = false
        } catch {
            guard !Task.isCancelled else { return }
            fullSummary = nil
            self.error = error.localizedDescription
        }
        fullTask = nil
    }

    /// 按行把长文切成不超过 `size` 个字符的块(不切断句子)。
    nonisolated static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if !current.isEmpty, current.count + line.count + 1 > size {
                result.append(current)
                current = ""
            }
            current += current.isEmpty ? String(line) : "\n" + line
        }
        if !current.isEmpty { result.append(current) }
        return result
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
            error = String(localized: "请先在 设置 › AI 服务 中配置", bundle: .l10n)
            return
        }
        let transcript = subtitles.transcript
        let pending = pendingEntries
        guard let first = pending.first, let last = pending.last else { return }
        var text = pending.map(\.text).joined(separator: "\n")
        if text.count > Self.maxCharacters { text = String(text.suffix(Self.maxCharacters)) }
        let previous = sections.last { !$0.generating }?.text
        let section = Section(range: "\(startOffset(before: first, in: transcript)) – \(transcript.offset(of: last))", text: "", generating: true)
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

    /// 一段的开始时间。句子记的是定稿时刻(这句说完的时候),所以开始时间取上一句的定稿时刻
    /// (第一句从 00:00:00 开始),各段时间首尾相连,不会出现中间空了一截的错觉。
    private func startOffset(before entry: CaptionTranscript.Entry, in transcript: CaptionTranscript) -> String {
        guard let index = transcript.entries.firstIndex(where: { $0.id == entry.id }), index > 0 else { return "00:00:00" }
        return transcript.offset(of: transcript.entries[index - 1])
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
        fullTask?.cancel()
        fullTask = nil
        fullSummary = nil
        enabled = false
        sections = []
        error = nil
        summarizedThrough = nil
        lastSummaryAt = .distantPast
    }
}
