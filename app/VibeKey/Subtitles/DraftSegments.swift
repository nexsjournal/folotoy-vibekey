import Foundation

/// 把正在说、还没成句的"已确认文字"切成短的翻译片段(边说边译用,纯函数,便于测试)。
///
/// 为什么需要:有的流式识别(如火山引擎)识别中的结果几乎不打句号,句子要等引擎定稿(可能十几秒)才切得出来。
/// 如果把整段越来越长的文字反复整体重翻,译文开头会不停变化,既闪烁又跟不上(实测)。
/// 同传系统的通行做法是按片段翻译(segment-based / chunk-based simultaneous translation):
/// - 在逗号、句号等处切出片段;一直没有标点时,每满一定长度在词边界硬切;
/// - 已确认文字只在末尾增长(LocalAgreement),切分规则只看前文,所以已经切出的片段不会再变 —— 每段只翻译一次,译文稳定;
/// - 只有最后不足一段的尾巴需要反复重翻(很短,DraftStabilizer 处理闪烁)。
nonisolated enum DraftSegments {
    /// 片段长度(按"词"计:拉丁文字 1 个词 = 1,中日韩 1 个字 = 0.6):至少这么长才在标点处切,满这么长就硬切。
    static let minLength = 5.0
    static let maxLength = 14.0

    struct Segment: Equatable, Sendable {
        let text: String
        /// 片段包含的词数(CaptionSegmenter.tokenize 的口径),用来在识别结果里定位尾巴。
        let tokens: Int
    }

    private static let breaks: Set<Character> = [",", ".", "?", "!", ";", ":", "，", "。", "？", "！", "；", "：", "、"]

    /// 切出完整的片段(最后不满一段的部分不返回,由调用方作为尾巴处理)。片段只在两个词之间切,不在文字末尾切
    /// (末尾的标点在识别中还会变)。
    static func split(_ confirmed: String) -> [Segment] {
        let tokens = CaptionSegmenter.tokenize(confirmed)
        var result: [Segment] = []
        var start = 0
        var length = 0.0
        for index in tokens.indices.dropLast() {
            length += tokens[index].word.unicodeScalars.contains(where: TranscriptText.isCJK) ? 0.6 : 1
            let gap = confirmed[tokens[index].range.upperBound..<tokens[index + 1].range.lowerBound]
            let atBreak = gap.contains(where: breaks.contains)
            guard (atBreak && length >= minLength) || length >= maxLength else { continue }
            let end = gap.lastIndex(where: breaks.contains).map { confirmed.index(after: $0) } ?? tokens[index].range.upperBound
            let text = String(confirmed[tokens[start].range.lowerBound..<end]).trimmingCharacters(in: .whitespaces)
            result.append(Segment(text: text, tokens: index + 1 - start))
            start = index + 1
            length = 0
        }
        return result
    }

    /// 文字里跳过前 `count` 个词之后的部分(尾巴)。
    static func dropTokens(_ count: Int, from text: String) -> String {
        guard count > 0 else { return text }
        let tokens = CaptionSegmenter.tokenize(text)
        guard count < tokens.count else { return "" }
        return String(text[tokens[count].range.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }
}
