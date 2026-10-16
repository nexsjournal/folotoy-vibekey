import Foundation

/// 把流式识别结果变成"只增不改"的句子序列(字幕条的显示单位)。
///
/// 业内做法:
/// - 流式识别的中间结果会不断修正,只有稳定的部分才交给翻译和显示(Google / AWS / Azure 的
///   "stable partial results")。这里用 LocalAgreement-2(Whisper-Streaming,Macháček 等 2023):
///   连续两次识别结果开头一致的词才算确认;确认的部分只增不改。
/// - 只从已确认的文字里切句(SentenceSplitter 对只在末尾增长的文字保持稳定),
///   所以已经给出的句子永远不会被改写、也不会漏掉——不需要按内容去猜对应关系。
/// - 定稿时:用已给出部分的最后几个词在定稿文字里定位接续的位置,只返回还没给出的句子;
///   识别引擎有时只定稿正在识别内容的前一段,已给出但超出这段定稿的部分留到下一次定稿抵扣。
/// 纯数据结构,便于测试。
nonisolated struct CaptionSegmenter: Equatable, Sendable {
    private var previous: [Token] = []
    private var previousText = ""
    private var confirmedCount = 0
    private var confirmedText = ""
    /// 本段已经作为句子给出的词数(定稿时用来抵扣)。
    private(set) var emittedTokens = 0
    /// 已给出部分的最后几个词,定稿时用来定位接续的位置。
    private var emittedTail: [String] = []

    /// 定位用的尾部词数。
    private static let tailLength = 3

    mutating func reset() { self = CaptionSegmenter() }

    /// 识别中的结果。返回新确认的完整句子(按顺序)和还在变化 / 还没成句的部分(界面暗色显示)。
    mutating func hypothesis(_ text: String) -> (sentences: [String], live: String) {
        guard !text.isEmpty else { return ([], "") }
        let tokens = Self.tokenize(text)
        let agreed = zip(previous, tokens).prefix { $0.word == $1.word }.count
        if agreed > 0 {
            // 已确认的文字只往后追加,不用新结果改写(引擎之后把句号改成逗号,也不影响已经给出的句子)。
            if agreed > confirmedCount {
                let start = tokens[confirmedCount].range.lowerBound
                let gapStart = confirmedCount > 0 ? tokens[confirmedCount - 1].range.upperBound : text.startIndex
                let gap = String(text[gapStart..<start])
                // 已确认部分末尾已经有标点时只补空白,否则连同新结果里的标点一起补上。
                let separator = confirmedText.last.map { !$0.isLetter && !$0.isNumber } == true
                    ? (gap.contains(where: \.isWhitespace) ? " " : "")
                    : gap
                confirmedText += separator + String(text[start..<tokens[agreed - 1].range.upperBound])
                confirmedCount = agreed
            }
            // 紧跟最后一个确认词的标点在两次结果里也一致时一并确认(句号确认了,句子才算说完)。
            if confirmedText.last.map({ $0.isLetter || $0.isNumber }) == true {
                let end = tokens[agreed - 1].range.upperBound
                let gap = Self.punctuation(in: text, after: end, until: agreed < tokens.count ? tokens[agreed].range.lowerBound : text.endIndex)
                let previousEnd = previous[agreed - 1].range.upperBound
                let previousGap = Self.punctuation(in: previousText, after: previousEnd,
                                                   until: agreed < previous.count ? previous[agreed].range.lowerBound : previousText.endIndex)
                if agreed == confirmedCount, !gap.text.isEmpty, gap.text == previousGap.text { confirmedText += gap.text }
            }
        }
        previous = tokens
        previousText = text
        let sentences = takeNewSentences(from: SentenceSplitter.split(confirmedText, final: false).complete)
        let live = emittedTokens < tokens.count ? String(text[tokens[emittedTokens].range.lowerBound...]) : ""
        return (sentences, live.trimmingCharacters(in: .whitespaces))
    }

    /// 定稿。返回这段定稿里还没给出的句子;之后开始新的一段。
    mutating func final(_ text: String) -> [String] {
        let tokens = Self.tokenize(text)
        let start = alignedStart(in: tokens)
        let remainder = start < tokens.count ? String(text[tokens[start].range.lowerBound...]) : ""
        let sentences = SentenceSplitter.split(remainder, final: true).complete
        // 已给出的内容超出了这段定稿(多段分次定稿):多出来的词留给下一段抵扣。
        let carry = max(0, emittedTokens - max(start, tokens.count))
        let tail = carry > 0 ? emittedTail : []
        self = CaptionSegmenter()
        emittedTokens = carry
        emittedTail = tail
        return sentences
    }

    // MARK: - 内部

    /// 从已确认文字切出的完整句子里,取出还没给出的(按词数累计判断)。
    private mutating func takeNewSentences(from sentences: [String]) -> [String] {
        var result: [String] = []
        var end = 0
        for sentence in sentences {
            let words = Self.tokenize(sentence)
            end += words.count
            guard end > emittedTokens else { continue }
            result.append(sentence)
            emittedTokens = end
            emittedTail = Array((emittedTail + words.map(\.word)).suffix(Self.tailLength))
        }
        return result
    }

    /// 定稿文字里接着已给出部分的位置:优先用最后几个词定位(识别结果前后可能有细微出入),
    /// 找不到就按词数估计。
    private func alignedStart(in tokens: [Token]) -> Int {
        guard emittedTokens > 0 else { return 0 }
        let words = tokens.map(\.word)
        if !emittedTail.isEmpty, words.count >= emittedTail.count {
            let matches = (0...(words.count - emittedTail.count)).filter {
                Array(words[$0..<($0 + emittedTail.count)]) == emittedTail
            }
            if let best = matches.min(by: { abs($0 + emittedTail.count - emittedTokens) < abs($1 + emittedTail.count - emittedTokens) }) {
                return best + emittedTail.count
            }
        }
        return min(emittedTokens, tokens.count)
    }

    /// 两个词之间的标点(去掉空白)和它结束的位置。
    private static func punctuation(in text: String, after start: String.Index, until end: String.Index) -> (text: String, end: String.Index) {
        guard start < end else { return ("", start) }
        let gap = text[start..<end]
        let marks = gap.filter { !$0.isWhitespace }
        let last = gap.lastIndex(where: { !$0.isWhitespace }).map { text.index(after: $0) } ?? start
        return (String(marks), last)
    }

    struct Token: Equatable, Sendable {
        let word: String
        let range: Range<String.Index>
    }

    /// 切成词:连续的字母数字(含撇号)为一个词,中日韩文字每个字一个词,忽略大小写和标点。
    static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        func close(_ end: String.Index) {
            if let s = start { result.append(Token(word: text[s..<end].lowercased(), range: s..<end)) }
            start = nil
        }
        while index < text.endIndex {
            let c = text[index]
            let next = text.index(after: index)
            if c.unicodeScalars.contains(where: TranscriptText.isCJK), !c.isPunctuation {
                close(index)
                result.append(Token(word: String(c), range: index..<next))
            } else if c.isLetter || c.isNumber || c == "'" || c == "’" {
                if start == nil { start = index }
            } else {
                close(index)
            }
            index = next
        }
        close(text.endIndex)
        return result
    }
}
