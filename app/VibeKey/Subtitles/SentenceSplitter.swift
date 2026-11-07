import Foundation

/// 把识别文字切成句子,作为字幕翻译和显示的单位(影视字幕以句为单位,而不是识别引擎一次吐出的一大段)。
///
/// 规则(对正在增长的文字保持稳定:文字只在末尾增加时,已切出的句子不会再变,
/// 这样"识别中先切出并显示的句子"和"定稿后切出的句子"能按顺序一一对应):
/// - 句末标点(. ? ! 。？！…,可带引号括号)后面是空白、结尾或中日韩文字时断句;"3.14" 这类小数不断。
/// - 长句在逗号处再切:第一个位于"分量" ≥ 30 处、且后面还有 ≥ 15 分量的逗号(中日韩 1 字 = 1,其他 2 字符 = 1)。
/// - 太短的句子(拉丁文字少于 6 个词,中日韩少于 8 个字)和下一句合并;定稿时末尾的短句并入前一句。
///   识别中的句号并不可靠(引擎常在半句处先打句号、定稿时又去掉),只切出几个词的碎片单独显示、单独翻译,
///   读起来像漏了内容(实测),所以宁可等到意思完整的长度再显示。
/// - 正在识别的文字(`final == false`):最后一段算"还在说"(rest);若最后一个完整句是短句,也放回 rest 等下一句。
/// 纯函数,便于测试。
nonisolated enum SentenceSplitter {
    private static let terminators: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]
    private static let commas: Set<Character> = [",", "，", ";", "；"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』"]
    static let clauseMinWeight = 30.0
    static let clauseRestWeight = 15.0
    static let shortWords = 6
    static let shortCJK = 8

    static func split(_ text: String, final: Bool) -> (complete: [String], rest: String) {
        let (sentences, tail) = sentencesAndTail(text)
        // 句子和未完部分都按逗号再切;未完部分切出的前几段算完整。
        var pieces = sentences.flatMap(clauses)
        var rest = ""
        if !tail.isEmpty {
            var tailPieces = clauses(tail)
            rest = tailPieces.removeLast()
            pieces += tailPieces
        }
        if final, !rest.isEmpty {
            pieces.append(rest)
            rest = ""
        }
        var merged = mergeShort(pieces)
        if !final, let last = merged.last, isShort(last) {
            merged.removeLast()
            rest = TranscriptText.join([last, rest])
        } else if final, merged.count >= 2, let last = merged.last, isShort(last) {
            // 定稿没有后文可等了:末尾的短句并入前一句。
            merged.removeLast()
            merged[merged.count - 1] = TranscriptText.join([merged[merged.count - 1], last])
        }
        return (merged, rest)
    }

    /// 按句末标点切分;返回完整句子和最后没有句末标点的部分。
    private static func sentencesAndTail(_ text: String) -> ([String], String) {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if terminators.contains(c) {
                // 连续标点和收尾符号属于同一句(如 "?!"、"。」"、"...")。
                while i + 1 < chars.count, terminators.contains(chars[i + 1]) || closers.contains(chars[i + 1]) {
                    i += 1
                    current.append(chars[i])
                }
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let isDecimal = c == "." && (current.dropLast().last?.isNumber ?? false) && (next?.isNumber ?? false)
                if !isDecimal, next == nil || next!.isWhitespace || isCJK(next!) || isCJK(c) {
                    let sentence = current.trimmingCharacters(in: .whitespaces)
                    if !sentence.isEmpty { sentences.append(sentence) }
                    current = ""
                }
            }
            i += 1
        }
        return (sentences, current.trimmingCharacters(in: .whitespaces))
    }

    /// 长句在逗号处切开(规则见类型说明)。至少返回一段。
    static func clauses(_ text: String) -> [String] {
        var result: [String] = []
        var remaining = Substring(text)
        while true {
            var weight = 0.0
            var cut: Substring.Index?
            for index in remaining.indices {
                let c = remaining[index]
                weight += isCJK(c) ? 1 : 0.5
                if commas.contains(c), weight >= clauseMinWeight,
                   SentenceSplitter.weight(remaining[remaining.index(after: index)...]) >= clauseRestWeight {
                    cut = index
                    break
                }
            }
            guard let cut else { break }
            result.append(String(remaining[...cut]).trimmingCharacters(in: .whitespaces))
            remaining = remaining[remaining.index(after: cut)...]
        }
        let last = String(remaining).trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || result.isEmpty { result.append(last) }
        return result
    }

    /// 短句并入下一句(最后一句是短句时保留)。
    private static func mergeShort(_ pieces: [String]) -> [String] {
        var result: [String] = []
        var carry = ""
        for (index, piece) in pieces.enumerated() where !piece.isEmpty {
            let joined = carry.isEmpty ? piece : TranscriptText.join([carry, piece])
            if isShort(joined), index < pieces.count - 1 {
                carry = joined
            } else {
                result.append(joined)
                carry = ""
            }
        }
        if !carry.isEmpty { result.append(carry) }
        return result
    }

    static func isShort(_ sentence: String) -> Bool {
        let cjk = sentence.unicodeScalars.filter(TranscriptText.isCJK).count
        if cjk > 0 { return cjk < shortCJK }
        return sentence.split(whereSeparator: \.isWhitespace).count < shortWords
    }

    private static func weight(_ text: Substring) -> Double {
        text.reduce(0) { $0 + (isCJK($1) ? 1 : ($1.isWhitespace ? 0 : 0.5)) }
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains(where: TranscriptText.isCJK)
    }
}
