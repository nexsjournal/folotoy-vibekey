import Foundation

/// 词汇表里的一行。`DeepSeek = DIPSEEK, deep seek, 迪普希克` 表示正式写法与常见误识别。
nonisolated struct VocabularyEntry: Equatable, Sendable {
    let term: String
    let aliases: [String]
}

/// 识别结果后的确定性纠错：按词汇表把已知误识别替换成正式写法。
/// 纯字符串处理，毫秒级、零额度，不依赖大模型；AI 润色仍然可选。
nonisolated enum VocabularyCorrector {
    static func parse(_ lines: [String]) -> [VocabularyEntry] {
        lines.compactMap { raw in
            let line = raw
                .replacingOccurrences(of: "＝", with: "=")
                .replacingOccurrences(of: "→", with: "=")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let term = parts[0].trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { return nil }
            let aliases = parts.count > 1
                ? parts[1].split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0 == ";" || $0 == "；" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : []
            return VocabularyEntry(term: term, aliases: aliases)
        }
    }

    /// 写进 ASR 提示词 / Apple Speech contextualStrings 的词（只放正式写法）。
    static func promptTerms(_ entries: [VocabularyEntry]) -> [String] {
        entries.map(\.term)
    }

    /// 写进 AI 润色 / 翻译提示词的词，把常见误识别也带上，帮助模型判断。
    static func promptDescriptions(_ entries: [VocabularyEntry]) -> [String] {
        entries.map { entry in
            entry.aliases.isEmpty ? entry.term : "\(entry.term) (often misheard as \(entry.aliases.joined(separator: ", ")))"
        }
    }

    static func apply(_ text: String, entries: [VocabularyEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        var aliasMap: [String: String] = [:]
        var fuzzyTerms: [(normalized: String, term: String)] = []
        for entry in entries {
            let normalizedTerm = normalize(entry.term)
            // 太短的词（AI、Go）容易误伤普通单词；只接受显式别名。
            if normalizedTerm.count >= 4 { aliasMap[normalizedTerm] = entry.term }
            if normalizedTerm.count >= 7 { fuzzyTerms.append((normalizedTerm, entry.term)) }
            for alias in entry.aliases {
                let normalized = normalize(alias)
                guard !normalized.isEmpty else { continue }
                aliasMap[normalized] = entry.term
            }
        }

        var result = text
        // 中文别名直接做字面替换（“迪普希克” → “DeepSeek”）。
        for entry in entries {
            for alias in entry.aliases where containsHan(alias) && alias.count >= 2 {
                result = result.replacingOccurrences(of: alias, with: entry.term)
            }
        }

        var replacements: [(NSRange, String)] = []
        let ns = result as NSString
        let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9]*(?:[._'’-][A-Za-z0-9]+)*"#)
        let tokens = regex?.matches(in: result, range: NSRange(location: 0, length: ns.length)) ?? []
        var index = 0
        while index < tokens.count {
            var matched = false
            // 最多合并 3 个词，处理 “deep seek” → DeepSeek、“claude code” → Claude Code。
            for width in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let first = tokens[index]
                let last = tokens[index + width - 1]
                guard gapIsJoinable(ns, from: first, to: last, count: width) else { continue }
                let phrase = ns.substring(with: NSRange(
                    location: first.range.location,
                    length: last.range.location + last.range.length - first.range.location))
                let normalized = normalize(phrase)
                if let term = aliasMap[normalized] {
                    replacements.append((NSRange(location: first.range.location, length: last.range.location + last.range.length - first.range.location), term))
                    index += width
                    matched = true
                    break
                }
                if width == 1, let term = fuzzyMatch(normalized, terms: fuzzyTerms) {
                    replacements.append((first.range, term))
                    index += 1
                    matched = true
                    break
                }
            }
            if !matched { index += 1 }
        }

        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return result
    }

    private static func gapIsJoinable(_ text: NSString, from first: NSTextCheckingResult,
                                      to last: NSTextCheckingResult, count: Int) -> Bool {
        guard count > 1 else { return true }
        let start = first.range.location + first.range.length
        let end = last.range.location
        guard end >= start else { return false }
        let gap = text.substring(with: NSRange(location: start, length: end - start))
        return gap.range(of: #"^[\s\-_]*$"#, options: .regularExpression) != nil
    }

    private static func fuzzyMatch(_ candidate: String, terms: [(normalized: String, term: String)]) -> String? {
        guard candidate.count >= 7 else { return nil }
        for entry in terms {
            guard candidate.first == entry.normalized.first else { continue }
            let limit = entry.normalized.count >= 9 ? 2 : 1
            if levenshtein(candidate, entry.normalized) <= limit { return entry.term }
        }
        // DIPSEEK → DeepSeek 是插入 + 替换两个编辑；对 8 个字符的词放宽到 2，但要求前缀相同。
        for entry in terms where entry.normalized.count >= 8 {
            if levenshtein(candidate, entry.normalized) <= 2 { return entry.term }
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        for i in 1...left.count {
            var current = [i]
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost))
            }
            previous = current
        }
        return previous[right.count]
    }
}
