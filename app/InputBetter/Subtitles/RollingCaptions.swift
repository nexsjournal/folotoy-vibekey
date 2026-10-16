import Foundation

/// 字幕条上的一句(SentenceSplitter 切出、CaptionSegmenter 确认的句子)。
nonisolated struct CaptionUnit: Identifiable, Equatable, Sendable {
    let id = UUID()
    var source: String
    /// 译文:nil = 还没有;"" = 原文已是目标语言,不需要译文。
    var translation: String?
    /// 翻译失败,不再等待。
    var translationFailed = false
    /// 已经接进译文行的译文(接上后锁定:之后 AI 润色版到达也不改字幕条,避免已显示的文字跳动)。
    var shownTranslation: String?
    /// 对应的字幕记录句子(只有 AI 能翻译时关联,AI 译文到达时同步过来)。
    var entryID: UUID?
    let createdAt: Date

    init(source: String, entryID: UUID? = nil, createdAt: Date = Date()) {
        self.source = source
        self.entryID = entryID
        self.createdAt = createdAt
    }
}

/// 字幕条的两行滚动字幕(同传类应用的通行形式:讯飞 / 腾讯会议 / Google Meet 翻译字幕):
/// - 原文行跟着语音实时走:已确认的句子 + 正在说的部分(还会变,略暗);
/// - 译文行按句出现:按句子顺序把译文接到末尾,所以通常比原文慢一两句;已接上的译文不再改动;
///   某句等译文超过 `timeout` 秒(或翻译失败)就跳过它,不让后面的句子一直等。
/// 界面把两行各放进固定 2 行高的框里底部对齐,写满后最旧的一行整行滚出。
///
/// 换行稳定的关键:文字的起点(锚点)固定、只在末尾增长,换行位置就不会变;
/// 只在累积超过 `trimAt` 个字符时,按整句把锚点往后移(偶尔一次),不会每次更新都整体重排。
/// 纯数据结构,便于测试。
nonisolated struct RollingCaptions: Equatable, Sendable {
    /// 原文行:已确认部分 + 正在说的部分(带分隔空格)。
    private(set) var sourceFinal = ""
    private(set) var sourceLive = ""
    /// 译文行。
    private(set) var translation = ""

    private var sourceAnchor = 0
    private var translationAnchor = 0

    /// 超过这个字符数时移动锚点,移到剩下不超过 `keep` 个字符。
    static let trimAt = 420
    static let keep = 160

    var hasSource: Bool { !sourceFinal.isEmpty || !sourceLive.isEmpty }

    mutating func reset() { self = RollingCaptions() }

    /// 前面 `count` 句被裁掉后同步锚点。
    mutating func dropped(_ count: Int) {
        sourceAnchor = max(0, sourceAnchor - count)
        translationAnchor = max(0, translationAnchor - count)
    }

    /// 重新计算两行文字。会把刚接上译文行的句子标记为已显示(锁定译文)。
    mutating func update(_ units: inout [CaptionUnit], live: String, translating: Bool, timeout: TimeInterval, now: Date) {
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

        // 译文行:按顺序接上已有译文的句子;遇到还在等译文的句子就停(超时 / 失败的跳过)。
        guard translating else {
            translation = ""
            return
        }
        for index in units.indices where index >= translationAnchor && units[index].shownTranslation == nil {
            if let text = units[index].translation {
                units[index].shownTranslation = text
            } else if units[index].translationFailed || now.timeIntervalSince(units[index].createdAt) > timeout {
                units[index].shownTranslation = ""
            } else {
                break
            }
        }
        var translations = units[translationAnchor...].compactMap(\.shownTranslation).filter { !$0.isEmpty }
        while TranscriptText.join(translations).count > Self.trimAt / 2, translations.count > 1 {
            translations.removeFirst()
            translationAnchor = nextTranslationAnchor(units, after: translationAnchor)
            if TranscriptText.join(translations).count <= Self.keep / 2 { break }
        }
        translation = TranscriptText.join(translations)
    }

    /// 译文锚点移过下一句有译文的句子。
    private func nextTranslationAnchor(_ units: [CaptionUnit], after anchor: Int) -> Int {
        var index = anchor
        while index < units.count, (units[index].shownTranslation ?? "").isEmpty { index += 1 }
        return min(index + 1, units.count)
    }
}
