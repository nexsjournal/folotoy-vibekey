import Foundation

/// 边说边译:给正在说、还没成句的部分不断给出暂定译文(字幕条译文行末尾略暗显示)。
/// 调用链:CaptionFeed.partial → update(已确认文字, 正在说的全部文字)
///   → DraftSegments.split(已确认文字切成短片段)→ 每段 SentenceTranslator.translate 一次(结果稳定;句子确认后同一段可直接复用)
///   → 不足一段的尾巴按节流策略 TranslationService.draft 重翻 → DraftStabilizer(遮尾 + 只增,一致两次才允许改写)
///   → shown = 各段译文 + 尾巴译文 → onChange(CaptionFeed 刷新字幕条);
///   句子确认 / 定稿时 CaptionFeed 用 drafts(for:) 把对应片段的译文交给这些句子,再 reset。
/// - 只用系统翻译 / 在线服务(AI 太慢,整句翻译时逐字显示代替);
/// - 尾巴同一时间只有一个请求;reset 之后返回的旧结果丢弃(代数)。
@MainActor
final class LiveDraft {
    /// 当前显示的暂定译文。
    private(set) var shown = ""
    var onChange: () -> Void = {}

    private let service: TranslationService
    private let sentences: SentenceTranslator
    private var stabilizer = DraftStabilizer()
    private var generation = 0
    private var inFlight = false
    /// 已切出的片段和各自的译文(nil = 还在翻译)。
    private var segments: [DraftSegments.Segment] = []
    private var segmentTranslations: [String?] = []
    /// 尾巴:最新的待译文字和请求参数(请求返回后用它判断要不要再译一次)。
    private var latest: (text: String, target: TargetLanguage, method: TranslationMethod)?
    /// 上一次发出尾巴请求的文字和时间(节流)。
    private var requested: (text: String, at: Date)?
    private var tailShown = ""

    init(service: TranslationService, sentences: SentenceTranslator) {
        self.service = service
        self.sentences = sentences
    }

    func reset() {
        generation += 1
        stabilizer.reset()
        shown = ""
        tailShown = ""
        segments = []
        segmentTranslations = []
        latest = nil
        requested = nil
        inFlight = false
    }

    /// 识别结果更新了。`confirmed`:已确认、还没成句的文字(只在末尾增长);`live`:正在说的全部文字(含未确认部分)。
    func update(confirmed: String, live: String, target: TargetLanguage, method: TranslationMethod) {
        guard LiveDraftPolicy.rule(for: method) != nil else { return }
        let split = DraftSegments.split(confirmed)
        // 新切出的片段:各翻译一次。已有片段不变(规则只看前文);万一识别改写了已确认部分,从变化处重来。
        let common = zip(segments, split).prefix { $0 == $1 }.count
        if common < segments.count {
            segments.removeSubrange(common...)
            segmentTranslations.removeSubrange(common...)
        }
        if split.count > segments.count {
            for segment in split[segments.count...] {
                segments.append(segment)
                segmentTranslations.append(nil)
                translateSegment(segment, index: segments.count - 1, target: target, method: method)
            }
            // 尾巴从新的位置开始:重新稳定。
            stabilizer.reset()
            tailShown = ""
            requested = nil
        }
        let tail = DraftSegments.dropTokens(segments.reduce(0) { $0 + $1.tokens }, from: live)
        latest = tail.isEmpty ? nil : (tail, target, method)
        if tail.isEmpty, !tailShown.isEmpty {
            tailShown = ""
            stabilizer.reset()
        }
        refreshShown()
        requestIfNeeded()
    }

    /// 定时检查(CaptionFeed 每 0.5 秒调用):说话停顿时没有新的识别结果,节流挡住的最后一次也要补上。
    func tick() {
        requestIfNeeded()
    }

    /// 句子确认 / 定稿时取走对应的暂定译文:按顺序把片段分给各句(片段的词正好是这句开头的部分才给),
    /// 返回每句的暂定译文(没有对应片段时为 nil)。
    func drafts(for sources: [String]) -> [String?] {
        var index = 0
        return sources.map { source in
            var words = CaptionSegmenter.tokenize(source).map(\.word)
            var parts: [String] = []
            while index < segments.count, let translation = segmentTranslations[index] {
                let segmentWords = CaptionSegmenter.tokenize(segments[index].text).map(\.word)
                guard words.starts(with: segmentWords) else { break }
                words.removeFirst(segmentWords.count)
                parts.append(translation)
                index += 1
            }
            return parts.isEmpty ? nil : TranscriptText.join(parts)
        }
    }

    // MARK: - 内部

    private func translateSegment(_ segment: DraftSegments.Segment, index: Int, target: TargetLanguage, method: TranslationMethod) {
        let current = generation
        Task {
            let result = await sentences.translate(segment.text, target: target, method: method)
            guard current == generation, index < segments.count, segments[index] == segment else { return }
            // 失败的片段按空白处理,不挡住后面的片段;被取消的(换了设置)已经按代数丢弃,这里不会到。
            if case .cancelled = result { return }
            if case .translated(let text) = result { segmentTranslations[index] = text } else { segmentTranslations[index] = "" }
            CaptionTrace.log("segment #\(index) translated: \(result)")
            refreshShown()
        }
    }

    /// 显示内容 = 按顺序已翻译好的片段(遇到还在翻译的就停)+ 尾巴的暂定译文(前面的片段都好了才接上)。
    private func refreshShown() {
        let ready = segmentTranslations.prefix { $0 != nil }.compactMap { $0 }
        var parts = ready
        if ready.count == segmentTranslations.count, !tailShown.isEmpty { parts.append(tailShown) }
        let updated = TranscriptText.join(parts)
        // 刚切出的新片段还在翻译时不缩短显示内容(否则暂定译文会闪一下消失,等片段译文到了再出现)。
        if segmentTranslations.contains(where: { $0 == nil }), updated.count < shown.count { return }
        guard updated != shown else { return }
        shown = updated
        onChange()
    }

    private func requestIfNeeded() {
        guard !inFlight, let latest,
              LiveDraftPolicy.shouldRequest(latest.text, method: latest.method, last: requested, now: Date()) else { return }
        inFlight = true
        requested = (latest.text, Date())
        let current = generation
        let request = latest
        Task {
            let started = Date()
            let result = await service.draft(request.text, target: request.target, method: request.method)
            CaptionTrace.log("draft tail \(request.text.count) chars in \(String(format: "%.2f", Date().timeIntervalSince(started)))s stale=\(current != generation) result=\(result?.count ?? -1)")
            guard current == generation else { return }
            inFlight = false
            // 尾巴已经被切成片段(换了位置)时,这次结果作废。
            if let result, self.latest?.text.hasPrefix(request.text) == true {
                tailShown = stabilizer.update(result)
                refreshShown()
            }
            requestIfNeeded()
        }
    }
}

/// 边说边译的节流策略(纯函数,便于测试):多快重翻一次、至少多长才翻。
/// 系统翻译在本机、几十毫秒,可以跟得很紧;在线服务按字符计费、有网络延迟,间隔放长、原文要多长出几个词才重翻。
nonisolated enum LiveDraftPolicy {
    struct Rule: Equatable {
        /// 两次请求的最小间隔。
        let interval: TimeInterval
        /// 至少多少个词(中日韩按字)才开始翻。
        let minTokens: Int
        /// 比上次请求至少多出多少个词才重翻。
        let minGrowth: Int
    }

    static func rule(for method: TranslationMethod) -> Rule? {
        switch method {
        case .system: Rule(interval: 0.3, minTokens: 2, minGrowth: 1)
        case .provider: Rule(interval: 1.0, minTokens: 3, minGrowth: 3)
        case .llm: nil
        }
    }

    static func shouldRequest(_ text: String, method: TranslationMethod, last: (text: String, at: Date)?, now: Date) -> Bool {
        guard let rule = rule(for: method) else { return false }
        let tokens = CaptionSegmenter.tokenize(text).count
        guard tokens >= rule.minTokens else { return false }
        guard let last else { return true }
        guard text != last.text, now.timeIntervalSince(last.at) >= rule.interval else { return false }
        return tokens - CaptionSegmenter.tokenize(last.text).count >= rule.minGrowth || !DraftStabilizer.startsWith(text, last.text)
    }
}
