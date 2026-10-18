import Foundation

/// 字幕条上的一句(SentenceSplitter 切出、CaptionSegmenter 确认的句子)。
nonisolated struct CaptionUnit: Identifiable, Equatable, Sendable {
    let id = UUID()
    var source: String
    /// 整句译文:nil = 还没有;"" = 原文已是目标语言,不需要译文。
    var translation: String?
    /// 暂定译文:说这句时边说边译的结果,或 AI 逐字生成中的译文(整句译文到达前略暗显示)。
    var draft: String?
    /// 翻译失败,不再等待。
    var translationFailed = false
    /// 已经接进译文行、不再改动的内容(整句译文,或等不到译文时的替代内容)。
    var shownTranslation: String?
    /// 接进译文行的是替代内容(暂定译文或原文),按暂定样式(略暗)显示。
    var shownIsFallback = false
    /// 对应的字幕记录句子(用 AI 翻译时字幕条直接用记录的句子,AI 译文同步过来)。
    var entryID: UUID?
    /// 开始等译文的时间(重新翻译时会重置)。
    var createdAt: Date

    init(source: String, entryID: UUID? = nil, createdAt: Date = Date()) {
        self.source = source
        self.entryID = entryID
        self.createdAt = createdAt
    }
}

/// 译文区的一句(每句单独起一行,见 RollingCaptions.translationLines)。
nonisolated struct TranslationLine: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    /// 还没定下来(暂定译文 / 顶替内容 / 正在说的半句),略暗显示。
    let provisional: Bool
    /// 原文已是目标语言,这一行显示的是原文本身(原文区不显示时才需要显示,否则这句会从屏幕上消失)。
    var sameLanguage = false
}

/// 字幕条的滚动字幕(同传类应用的通行形式:讯飞 / 腾讯会议 / Google Meet 翻译字幕):
/// - 原文行跟着语音实时走:已确认的句子 + 正在说的部分(还会变,略暗);
/// - 译文行按句子顺序接上每句的译文,末尾接上正在说的半句的暂定译文(略暗),所以只比原文慢零点几秒;
///   整句译文到达后替换这句的暂定译文,之后锁定不再改动。
/// - 不丢句:一句的整句译文迟迟不到(或翻译失败)时,用它的暂定译文、没有就用原文顶替,不会被跳过;
///   顶替之后译文才到的,再换成译文(每句独立成段,不影响别的句子);只有一句什么都还没有时,后面的句子才等它;
///   原文已是目标语言的句子以 `sameLanguage` 行给出(原文区不显示时用它顶上)。
/// 界面把两行各放进最多若干行高的框里(原文 0–3 行、译文 2–5 行,用户可调)底部对齐,写满后最旧的一行整行滚出。
///
/// 译文按句分段(`translationLines`,每句单独起一行):读者的位置总在句首,一句的译文变化只影响它自己那一段,
/// 前面已读的句子不会重排;实测连续成段的译文在暂定译文替换、新行出现时整体跳动,读者找不到读到哪里。
/// 原文行仍是连续文字(次要,跟着语音走)。
/// 换行稳定的关键:文字的起点(锚点)固定、只在末尾增长,换行位置就不会变;
/// 只在累积超过 `trimAt` 个字符时,按整句把锚点往后移(偶尔一次),不会每次更新都整体重排。
/// 纯数据结构,便于测试。
nonisolated struct RollingCaptions: Equatable, Sendable {
    /// 原文行:已确认部分 + 正在说的部分(带分隔空格)。
    private(set) var sourceFinal = ""
    private(set) var sourceLive = ""
    /// 译文行:已定的部分 + 暂定的部分(略暗)。
    private(set) var translationFinal = ""
    private(set) var translationLive = ""
    /// 译文区按句分段的内容(最新的在最后;正在说的半句是最后一段)。
    private(set) var translationLines: [TranslationLine] = []
    /// 有句子正在等译文、译文行还没有任何内容可显示("翻译中…")。
    private(set) var translationWaiting = false
    /// 有句子什么都还没有(后面的句子在等它);CaptionFeed 据此决定何时丢掉 heldDraft。
    private(set) var unitsWaiting = false

    private var sourceAnchor = 0
    private var translationAnchor = 0

    /// 超过这个字符数时移动锚点,移到剩下不超过 `keep` 个字符。
    /// 要明显大于框里能显示的字数(最多 3 行原文 / 5 行译文),否则还没写满就被裁掉、框会跳。
    static let trimAt = 900
    static let keep = 420
    /// 译文区最多保留的句数(框里最多显示 5 行;保留 40 句,用户可以在字幕条上往回滚动看前面没读完的句子)。
    static let maxTranslationLines = 40

    var hasSource: Bool { !sourceFinal.isEmpty || !sourceLive.isEmpty }
    var translation: String { TranscriptText.join([translationFinal, translationLive].filter { !$0.isEmpty }) }

    mutating func reset() { self = RollingCaptions() }

    /// 前面 `count` 句被裁掉后同步锚点。
    mutating func dropped(_ count: Int) {
        sourceAnchor = max(0, sourceAnchor - count)
        translationAnchor = max(0, translationAnchor - count)
    }

    /// 重新开始译文行(换了目标语言 / 翻译方式、刚打开翻译):从第 `index` 句开始显示,之前的译文不再显示。
    mutating func restartTranslation(from index: Int) {
        translationAnchor = max(0, index)
        translationFinal = ""
        translationLive = ""
        translationLines = []
    }

    /// 重新计算原文和译文。整句译文接进译文行后锁定(写入 shownTranslation)。
    /// - Parameters:
    ///   - liveDraft: 正在说的半句的暂定译文;
    ///   - heldDraft: 有句子在等整句译文、又没有自己的暂定译文时,先顶上的上一份暂定译文;
    ///   - timeout: 一句等整句译文超过这么久,用暂定译文 / 原文顶替。
    mutating func update(_ units: inout [CaptionUnit], live: String, liveDraft: String = "", heldDraft: String = "",
                         translating: Bool, timeout: TimeInterval, now: Date) {
        sourceAnchor = min(sourceAnchor, units.count)
        translationAnchor = min(translationAnchor, units.count)

        // 原文行
        var sources = units[sourceAnchor...].map(\.source)
        while TranscriptText.join(sources).count > Self.trimAt, sources.count > 1 {
            sources.removeFirst()
            sourceAnchor += 1
            if TranscriptText.join(sources).count <= Self.keep { break }
        }
        let finalText = TranscriptText.join(sources)
        let full = TranscriptText.join(sources + [live])
        sourceFinal = finalText
        sourceLive = String(full.dropFirst(finalText.count))

        guard translating else {
            translationFinal = ""
            translationLive = ""
            translationLines = []
            translationWaiting = false
            unitsWaiting = false
            return
        }

        // 译文行:按句子顺序取每句当前能显示的内容;遇到什么都还没有的句子就停(后面的等它)。
        var parts: [(index: Int, text: String, settled: Bool)] = []
        // 原文已是目标语言的句子:译文区没有它的译文,记下来给"只显示译文"的布局用原文顶上(否则这句看不见)。
        var sameLanguageRows: [(index: Int, text: String)] = []
        var waiting = false
        for index in units.indices where index >= translationAnchor {
            if units[index].shownTranslation == nil {
                if let text = units[index].translation {
                    units[index].shownTranslation = text
                } else if units[index].translationFailed || now.timeIntervalSince(units[index].createdAt) > timeout {
                    // 等不到:用暂定译文顶替,没有就显示原文,保证这句的内容不丢。
                    units[index].shownTranslation = units[index].draft ?? units[index].source
                    units[index].shownIsFallback = true
                }
            } else if units[index].shownIsFallback, let text = units[index].translation, text != units[index].shownTranslation {
                // 顶替之后整句译文才到(在线服务偶发的长延迟):每句独立成段,替换不影响其他句子,所以允许再换一次。
                units[index].shownTranslation = text
                units[index].shownIsFallback = false
            }
            if let shown = units[index].shownTranslation {
                if !shown.isEmpty {
                    parts.append((index, shown, !units[index].shownIsFallback))
                } else {
                    sameLanguageRows.append((index, units[index].source))
                }
            } else if let draft = units[index].draft, !draft.isEmpty {
                parts.append((index, draft, false))
            } else {
                waiting = true
                break
            }
        }

        // 句子太多时按整句移动锚点(每句单独成段,去掉顶部的旧句子不会让其他句子重排)。
        while parts.count > Self.maxTranslationLines {
            translationAnchor = parts[0].index + 1
            parts.removeFirst()
        }
        sameLanguageRows.removeAll { $0.index < translationAnchor }

        // 前面连续"已定"的部分正常显示,从第一处暂定内容开始略暗。
        let settledCount = parts.prefix { $0.settled }.count
        translationFinal = TranscriptText.join(parts.prefix(settledCount).map(\.text))
        var liveParts = parts.dropFirst(settledCount).map(\.text)
        if waiting {
            if !heldDraft.isEmpty { liveParts.append(heldDraft) }
        } else if !liveDraft.isEmpty {
            liveParts.append(liveDraft)
        }
        let all = TranscriptText.join([translationFinal] + liveParts)
        translationLive = String(all.dropFirst(translationFinal.count))
        var rows = parts.map { (index: $0.index, line: TranslationLine(id: units[$0.index].id.uuidString, text: $0.text, provisional: !$0.settled)) }
        rows += sameLanguageRows.map { (index: $0.index, line: TranslationLine(id: units[$0.index].id.uuidString, text: $0.text, provisional: false, sameLanguage: true)) }
        var lines = rows.sorted { $0.index < $1.index }.map(\.line)
        let tail = waiting ? heldDraft : liveDraft
        if !tail.isEmpty { lines.append(TranslationLine(id: "live", text: tail, provisional: true)) }
        translationLines = lines
        unitsWaiting = waiting
        translationWaiting = waiting && parts.isEmpty && heldDraft.isEmpty
    }
}
