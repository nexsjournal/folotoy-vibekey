import Foundation

/// 字幕条的数据源:原文行跟着语音实时走,译文行按句接上并边说边译(RollingCaptions)。
///
/// 两条路径(每段话开始时按翻译方式选定,说完这段之前不变,避免中途换方式导致句子重复):
/// - 分句路径(不翻译、系统翻译、在线服务):
///   SubtitleController.handle(.partial) → partial → CaptionSegmenter.hypothesis(LocalAgreement 确认稳定的文字)
///     → 新确认的整句立即成为 CaptionUnit → SentenceTranslator(去重、合并)→ 整句译文;
///     正在说的部分 → LiveDraft(节流重翻 + DraftStabilizer 稳定)→ 暂定译文接在译文行末尾;
///   handle(.final) → final → CaptionSegmenter.final:只补上还没给出的句子。句子只增不改,不丢不重。
/// - 记录路径(AI 翻译):识别中不切句(AI 来不及按半句翻),定稿后按字幕记录的句子生成 unit 并关联,
///   SubtitleController 翻译记录的句子 → entryTranslation 把 AI 逐字生成的译文(暂定)和最终译文同步过来。
/// 每次有新内容(以及每 0.5 秒检查一次)→ RollingCaptions.update → 原文行 / 译文行。
@MainActor @Observable
final class CaptionFeed {
    /// 字幕条的两行文字。
    private(set) var captions = RollingCaptions()
    /// 最近一次翻译失败的原因(下一次成功时清除),字幕条上提示。
    private(set) var translationError: String?
    /// 本场字幕是否打开了翻译(由 SubtitleController 设置)。
    private(set) var translationEnabled = false
    /// 正在说、还没成句的部分。
    @ObservationIgnored private var liveRest = ""
    @ObservationIgnored private var units: [CaptionUnit] = []
    @ObservationIgnored private var segmenter = CaptionSegmenter()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let translation: TranslationService
    @ObservationIgnored private let sentences: SentenceTranslator
    @ObservationIgnored private let liveDraft: LiveDraft
    /// 这段话(从上次定稿到下次定稿)走哪条路径;nil = 还没开始。
    @ObservationIgnored private var utterancePath: Path?
    /// 换方式 / 目标语言 / 开关时递增,旧请求的结果丢弃。
    @ObservationIgnored private var generation = 0
    /// 新句子的整句译文还没到、又没有对应片段时,先显示的上一份暂定译文。
    @ObservationIgnored private var heldDraft = ""

    private enum Path { case segmented, entries }

    /// 保留的句子数上限(已显示的旧句子会被裁掉)。
    private static let maxUnits = 120

    init(settings: AppSettings, translation: TranslationService, sentences: SentenceTranslator) {
        self.settings = settings
        self.translation = translation
        self.sentences = sentences
        liveDraft = LiveDraft(service: translation, sentences: sentences)
        liveDraft.onChange = { [weak self] in self?.advance() }
    }

    private var method: TranslationMethod { settings.subtitleTranslationMethod }

    /// 字幕条是否显示译文(打开了翻译,且当前方式可用)。
    var translating: Bool { translationEnabled && translation.isAvailable(method) }

    /// 打开了翻译但当前方式不可用的原因。
    var unavailableReason: String? { translationEnabled ? translation.unavailableReason(method) : nil }

    /// 识别中已确认、但还没成句的文字(引擎给出空定稿时,SubtitleController 用它顶替定稿,不丢内容)。
    var pendingConfirmed: String { segmenter.pendingConfirmed }

    func start() {
        ticker?.cancel()
        // 定时刷新:等译文超时的句子要用替代内容顶上,停顿时边说边译也要补上最后一次。
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // 对象已释放就结束循环,不空转。
                guard let self else { return }
                liveDraft.tick()
                advance()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func reset() {
        ticker?.cancel()
        ticker = nil
        captions.reset()
        liveRest = ""
        units = []
        segmenter.reset()
        utterancePath = nil
        liveDraft.reset()
        heldDraft = ""
        translationError = nil
        translationEnabled = false
        generation += 1
    }

    /// 打开 / 关闭翻译。打开时从最新一句开始翻译(之前的句子不补,避免一次发出大量请求)。
    func setTranslationEnabled(_ enabled: Bool) {
        guard enabled != translationEnabled else { return }
        translationEnabled = enabled
        enabled ? restartTranslation() : liveDraft.reset()
        advance()
    }

    /// 换了目标语言或翻译方式:之前的译文不再显示,最新一句按新设置重新翻译。
    func restartTranslation() {
        generation += 1
        liveDraft.reset()
        heldDraft = ""
        translationError = nil
        guard !units.isEmpty else { return }
        let last = units.count - 1
        for index in units.indices where index < last && units[index].shownTranslation == nil {
            units[index].shownTranslation = ""
        }
        units[last].translation = nil
        units[last].draft = nil
        units[last].translationFailed = false
        units[last].shownTranslation = nil
        units[last].shownIsFallback = false
        units[last].createdAt = Date()
        captions.restartTranslation(from: last)
        // 关联记录的句子(以及 AI 方式)由 SubtitleController.translateLatest 重新翻译后同步过来。
        if translating, units[last].entryID == nil, !method.isLLM { requestTranslation(units[last]) }
        advance()
    }

    // MARK: - 输入

    func partial(_ text: String) {
        let path = utterancePath ?? currentPath
        utterancePath = path
        guard path == .segmented else {
            liveRest = text
            advance()
            return
        }
        let (newSentences, live) = segmenter.hypothesis(text)
        CaptionTrace.log("partial \(text.count) chars, +\(newSentences.count) units, live \(live.count) chars | …\(text.suffix(70))")
        liveRest = live
        addUnits(newSentences)
        if translating, settings.translationLiveDraft {
            liveDraft.update(confirmed: segmenter.pendingConfirmed, live: live, target: settings.subtitleTarget, method: method)
        }
        advance()
    }

    /// 定稿:`text` 是这次定稿的原文,`entries` 是它在字幕记录里切好的句子。
    func final(text: String, entries: [(text: String, entryID: UUID)]) {
        let path = utterancePath ?? currentPath
        utterancePath = nil
        CaptionTrace.log("final \(text.count) chars path=\(path)")
        if path == .segmented {
            addUnits(segmenter.final(text))
            // 这段话走的是分句路径、但现在用 AI 翻译(中途换的方式):分句路径的句子不自己请求 AI,
            // 按文字把它们和记录里的句子对上,AI 译文由 SubtitleController 翻译记录后同步过来(不重复请求)。
            if method.isLLM { link(entries) }
        } else {
            segmenter.reset()
            entries.forEach { add(CaptionUnit(source: $0.text, entryID: $0.entryID)) }
        }
        liveRest = ""
        liveDraft.reset()
        advance()
    }

    /// 把还没关联记录的句子按文字(忽略标点 / 大小写)和记录句子一一对上。
    private func link(_ entries: [(text: String, entryID: UUID)]) {
        var searchFrom = max(0, units.count - entries.count - 4)
        for entry in entries {
            let key = SentenceTranslator.normalize(entry.text)
            guard let i = units[searchFrom...].firstIndex(where: { $0.entryID == nil && SentenceTranslator.normalize($0.source) == key }) else { continue }
            units[i].entryID = entry.entryID
            searchFrom = i + 1
        }
    }

    /// 字幕记录里某句的 AI 译文有了进展(记录路径)。
    func entryTranslation(_ entryID: UUID, _ update: TranslationService.LineUpdate) {
        guard let i = units.lastIndex(where: { $0.entryID == entryID }) else { return }
        switch update {
        case .streaming(let text):
            units[i].draft = text
        case .final(let text):
            units[i].translation = text
            translationError = nil
        case .sameLanguage:
            units[i].translation = ""
        case .failed(let reason):
            units[i].translationFailed = true
            translationError = reason
        }
        advance()
    }

    #if DEBUG
    /// 仅调试:显示示例字幕。
    /// 没有译文的句子显示 `pendingDraft` 作为暂定译文,`liveTranslation` 是正在说的半句的暂定译文。
    func debugShow(_ sample: [(source: String, translation: String?)], live: String, pendingDraft: String, liveTranslation: String) {
        translationEnabled = true
        units = sample.map { item in
            var unit = CaptionUnit(source: item.source)
            unit.translation = item.translation
            if item.translation == nil { unit.draft = pendingDraft }
            return unit
        }
        liveRest = live
        captions.reset()
        var updated = captions
        updated.update(&units, live: live, liveDraft: liveTranslation, translating: true, timeout: 60, now: Date())
        captions = updated
    }
    #endif

    // MARK: - 内部

    /// 新开始的一段话走哪条路径:用 AI 翻译时走记录路径,其余走分句路径。
    private var currentPath: Path { translating && method.isLLM ? .entries : .segmented }

    /// 分句路径新确认的句子:说的时候已经有暂定译文的,先把对应片段的译文交给这句显示(整句译文到达后替换);
    /// 对不上片段的句子(定稿时引擎改写了文字),在整句译文到达前先显示之前的暂定译文(heldDraft),不出现空档。
    private func addUnits(_ sources: [String]) {
        guard !sources.isEmpty else { return }
        var drafts = translating ? liveDraft.drafts(for: sources) : sources.map { _ in nil }
        // 有句子对不上片段:整份暂定译文先整体顶着(不拆给个别句子,避免同一段内容显示两遍)。
        if translating, drafts.contains(where: { $0 == nil }) {
            if !liveDraft.shown.isEmpty { heldDraft = liveDraft.shown }
            drafts = sources.map { _ in nil }
        }
        for (source, draft) in zip(sources, drafts) {
            var unit = CaptionUnit(source: source)
            unit.draft = draft
            add(unit)
        }
        liveDraft.reset()
    }

    private func add(_ unit: CaptionUnit) {
        units.append(unit)
        CaptionTrace.log("unit #\(units.count - 1) draft=\(unit.draft != nil) \"\(unit.source.prefix(40))\"")
        // AI 方式的译文一律来自记录句子(SubtitleController 串行带上下文翻译),字幕条不再单独请求一次。
        if translating, unit.entryID == nil, !method.isLLM { requestTranslation(unit) }
    }

    /// 分句路径的整句译文(经 SentenceTranslator 去重、合并)。
    private func requestTranslation(_ unit: CaptionUnit) {
        let current = generation
        let target = settings.subtitleTarget, method = method
        Task {
            let result = await sentences.translate(unit.source, target: target, method: method)
            CaptionTrace.log("translated after \(String(format: "%.2f", Date().timeIntervalSince(unit.createdAt)))s: \(result) \"\(unit.source.prefix(30))\"")
            guard current == generation, let i = units.firstIndex(where: { $0.id == unit.id }) else { return }
            switch result {
            case .translated(let text):
                units[i].translation = text
                translationError = nil
            case .sameLanguage:
                units[i].translation = ""
            case .cancelled:
                return
            case .failed(let reason):
                units[i].translationFailed = true
                translationError = reason
            }
            advance()
        }
    }

    /// 一句等整句译文最多等多久(之后用暂定译文 / 原文顶替):系统翻译几十毫秒,在线服务几百毫秒,AI 几秒。
    private var timeout: TimeInterval {
        switch method {
        case .system: 3
        case .provider: 8
        case .llm: 15
        }
    }

    private func advance() {
        var updated = captions
        updated.update(&units, live: liveRest, liveDraft: translating ? liveDraft.shown : "",
                       heldDraft: translating ? heldDraft : "", translating: translating, timeout: timeout, now: Date())
        if !updated.unitsWaiting { heldDraft = "" }
        if updated != captions {
            if updated.translation != captions.translation || updated.translationWaiting != captions.translationWaiting {
                CaptionTrace.log("bar: final=\(updated.translationFinal.count) live=\(updated.translationLive.count) waiting=\(updated.translationWaiting) | \(updated.translationFinal)⟨\(updated.translationLive)⟩")
            }
            captions = updated
        }
        // 裁掉早已滚出字幕条的旧句子(两行都已经越过它们)。
        if units.count > Self.maxUnits {
            let drop = units.count - Self.maxUnits
            units.removeFirst(drop)
            captions.dropped(drop)
        }
    }
}
