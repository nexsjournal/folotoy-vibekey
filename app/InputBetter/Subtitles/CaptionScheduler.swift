import Foundation

/// 字幕条上的一句(按 SentenceSplitter 切出的句子)。
nonisolated struct CaptionUnit: Identifiable, Equatable, Sendable {
    let id = UUID()
    var source: String
    /// 译文:nil = 还没有;"" = 原文已是目标语言,只显示原文。
    var translation: String?
    /// 翻译失败,不再等待。
    var translationFailed = false
    /// 对应的字幕记录句子(定稿后关联,AI 译文到达时同步过来)。
    var entryID: UUID?
    let createdAt: Date

    init(source: String, entryID: UUID? = nil, createdAt: Date = Date()) {
        self.source = source
        self.entryID = entryID
        self.createdAt = createdAt
    }
}

/// 字幕条的显示调度(影视字幕的做法:一次显示一条,读完再换,显示后不再改动):
/// - 按顺序取出"已就绪"的句子(有译文,或翻译失败 / 超时,或没开翻译)组成一条字幕;
/// - 每条至少停留按阅读速度算出的时长(约每秒 8 个汉字 / 16 个字母,1.5–5 秒);
/// - 落后时追赶(积压 ≥ 3 句,或最早的一句已等待超过译文等待时长):每条只停留 0.8 秒,
///   并按顺序把更多句子合并成一条(太长时界面自动缩小字号)——从不跳过任何一句;
/// - 太久没有新内容(停留时长 + 6 秒)时清空,不让旧字幕一直挂着。
/// 纯数据结构,由 SubtitleController 定时调用 `advance`,便于测试。
nonisolated struct CaptionScheduler: Equatable, Sendable {
    struct Event: Equatable, Sendable {
        var source: String
        /// nil:没有译文(未开翻译或翻译失败),只显示原文。
        var translation: String?
        var shownAt: Date
        var duration: TimeInterval
    }

    private(set) var current: Event?
    /// 下一句要显示的位置(units 的下标)。
    private(set) var nextIndex = 0

    /// 一条字幕最多合并的句数和"字数"(中日韩 1 字 = 1,其他字符 2 个算 1)。
    static let maxUnitsPerEvent = 3
    static let maxWeight = 44.0
    /// 落后时一条字幕的上限(界面 2 行放不下时自动缩小字号)。
    static let maxUnitsWhenBehind = 5
    static let maxWeightWhenBehind = 70.0

    mutating func reset() {
        current = nil
        nextIndex = 0
    }

    /// 前面 `count` 句被裁掉后同步下标。
    mutating func dropped(_ count: Int) {
        nextIndex = max(0, nextIndex - count)
    }

    /// 推进一次;字幕有变化时返回 true。
    /// - Parameter timeout: 等译文的最长时间,超过就先只显示原文(也用来判断是否落后)。
    mutating func advance(_ units: [CaptionUnit], translating: Bool, timeout: TimeInterval, now: Date) -> Bool {
        var ready: [Int] = []
        if nextIndex < units.count {
            for index in nextIndex..<units.count {
                guard isReady(units[index], translating: translating, timeout: timeout, now: now) else { break }
                ready.append(index)
            }
        }
        guard !ready.isEmpty else {
            if let current, now.timeIntervalSince(current.shownAt) > current.duration + 6 {
                self.current = nil
                return true
            }
            return false
        }
        let backlog = ready.count >= 3 || now.timeIntervalSince(units[ready[0]].createdAt) > timeout
        if let current {
            let hold = backlog ? 0.8 : current.duration
            guard now.timeIntervalSince(current.shownAt) >= hold else { return false }
        }
        // 始终按顺序从最早的一句开始合并;落后时一条可以放更多内容。
        let group = fit(ready, units, translating,
                        maxUnits: backlog ? Self.maxUnitsWhenBehind : Self.maxUnitsPerEvent,
                        maxWeight: backlog ? Self.maxWeightWhenBehind : Self.maxWeight)
        let shown = group.map { units[$0] }
        let source = TranscriptText.join(shown.map(\.source))
        let translations = shown.compactMap { unit -> String? in
            guard translating, let translation = unit.translation, !translation.isEmpty else { return nil }
            return translation
        }
        let translation = translations.isEmpty ? nil : TranscriptText.join(translations)
        current = Event(source: source, translation: translation, shownAt: now,
                        duration: Self.duration(for: translation ?? source))
        nextIndex = (group.last ?? nextIndex) + 1
        return true
    }

    private func isReady(_ unit: CaptionUnit, translating: Bool, timeout: TimeInterval, now: Date) -> Bool {
        !translating || unit.translation != nil || unit.translationFailed
            || now.timeIntervalSince(unit.createdAt) > timeout
    }

    /// 从给定顺序开始取,能放进一条字幕的句子(至少一句)。
    private func fit(_ order: [Int], _ units: [CaptionUnit], _ translating: Bool, maxUnits: Int, maxWeight: Double) -> [Int] {
        var group: [Int] = []
        var weight = 0.0
        for index in order {
            let unit = units[index]
            let text = translating ? (unit.translation.flatMap { $0.isEmpty ? nil : $0 } ?? unit.source) : unit.source
            let w = Self.weight(text)
            if !group.isEmpty, group.count >= maxUnits || weight + w > maxWeight { break }
            group.append(index)
            weight += w
        }
        return group
    }

    /// 阅读时长:约每秒 8 个汉字(或 16 个字母),1.5–5 秒。
    static func duration(for text: String) -> TimeInterval {
        min(max(0.8 + weight(text) / 8, 1.5), 5)
    }

    static func weight(_ text: String) -> Double {
        let cjk = text.unicodeScalars.filter(TranscriptText.isCJK).count
        let other = text.unicodeScalars.filter { !TranscriptText.isCJK($0) && !CharacterSet.whitespaces.contains($0) }.count
        return Double(cjk) + Double(other) / 2
    }
}
