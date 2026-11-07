import Foundation

/// 半句暂定译文的稳定器(纯数据结构,便于测试)。
///
/// 业内做法:同传字幕用"重翻译"——原文每长一点就把整个半句重新翻译一次,译文能紧跟语音;
/// 代价是译文末尾反复变化(闪烁)。Google 的研究(Arivazhagan 等 2020《Re-translation strategies for long form,
/// simultaneous, spoken language translation》)用两个办法压住闪烁:
/// - mask-k:不显示译文最后 k 个词(末尾最依赖还没说出来的原文,变化最多);
/// - 只增不改:已经显示的部分不再改写,新译文只有在以已显示内容开头时才往后追加。
/// 这里两者都用:显示的暂定译文平时只会变长,不会跳动;整句说完后由整句译文一次替换。
/// 为了不"冻住"(重翻后开头的措辞变了,只增规则会让显示一直停在旧内容上):新措辞在连续两次译文里一致时
/// (LocalAgreement 用在译文上),允许用这段一致的内容替换已显示的内容(偶尔一次改写,换来跟得上)。
/// 只用于片段之后的短尾巴(见 DraftSegments),改写影响的范围很小。
nonisolated struct DraftStabilizer: Equatable, Sendable {
    /// 当前显示的暂定译文。
    private(set) var shown = ""
    /// 上一次的候选(遮尾后的译文),用于判断新措辞是否连续两次一致。
    private var previousCandidate = ""

    /// 遮住末尾的词数:中日韩文字按字算,遮 3 个;其他语言按词算,遮 2 个。
    static func maskCount(for text: String) -> Int {
        text.unicodeScalars.contains(where: TranscriptText.isCJK) ? 3 : 2
    }

    mutating func reset() {
        shown = ""
        previousCandidate = ""
    }

    /// 收到一次新的整半句译文,返回更新后的显示内容。
    @discardableResult
    mutating func update(_ translation: String) -> String {
        let tokens = CaptionSegmenter.tokenize(translation)
        let keep = tokens.count - Self.maskCount(for: translation)
        guard keep > 0 else { return shown }
        let candidate = String(translation[..<tokens[keep - 1].range.upperBound])
        defer { previousCandidate = candidate }
        // 只增不改:新的候选以已显示内容开头(按词比较,忽略标点和大小写差异)时直接采用。
        if shown.isEmpty || Self.startsWith(candidate, shown) {
            if candidate.count > shown.count { shown = candidate }
            return shown
        }
        // 措辞变了:和上一次候选一致的开头部分比已显示的还长,才改写成这部分。
        let agreed = Self.commonPrefix(candidate, previousCandidate)
        if CaptionSegmenter.tokenize(agreed).count > CaptionSegmenter.tokenize(shown).count { shown = agreed }
        return shown
    }

    /// 两段文字按词比较的共同开头(返回 `a` 里对应的原文)。
    static func commonPrefix(_ a: String, _ b: String) -> String {
        let ta = CaptionSegmenter.tokenize(a), tb = CaptionSegmenter.tokenize(b)
        let count = zip(ta, tb).prefix { $0.word == $1.word }.count
        guard count > 0 else { return "" }
        return String(a[..<ta[count - 1].range.upperBound])
    }

    /// `text` 的词序列是否以 `prefix` 的词序列开头。
    static func startsWith(_ text: String, _ prefix: String) -> Bool {
        let a = CaptionSegmenter.tokenize(text).map(\.word)
        let b = CaptionSegmenter.tokenize(prefix).map(\.word)
        return a.count >= b.count && Array(a.prefix(b.count)) == b
    }
}
