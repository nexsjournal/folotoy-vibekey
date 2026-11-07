import Foundation

/// 把要翻译的句子分成若干次请求(纯函数,便于测试):
/// 1. 每句先在本机识别语言,解析出具体的目标语言(目标是「自动」时中英混杂的内容会去往不同方向);
/// 2. 原文已经是目标语言的句子不发请求(省额度),直接记为"不需要译文";
/// 3. 按目标语言分组(系统翻译还要按源语言分组:它的会话是按语言对建立的),保持原来的顺序;
/// 4. 每组按这种方式的批量限制(句数、总长度)切块。
nonisolated enum BatchPlanner {
    struct Item: Equatable, Sendable {
        let id: UUID
        let text: String
    }

    /// 一次请求:同一语言对的若干句。
    struct Chunk: Equatable, Sendable {
        /// 识别出的源语言(系统翻译需要;在线服务 / AI 由服务端自动识别,不使用)。
        let source: Locale.Language?
        /// 具体的目标语言(不会是 .auto)。
        let target: TargetLanguage
        var items: [Item]
    }

    struct Plan: Equatable, Sendable {
        var chunks: [Chunk] = []
        /// 原文已是目标语言或为空、不需要翻译的句子。
        var skipped: [UUID] = []
    }

    /// - Parameters:
    ///   - groupBySource: 是否按源语言分组(系统翻译为 true)。
    ///   - detect: 识别一句的语言(识别不出返回 nil;调用方可以沿用上一句的语言)。
    static func plan(_ items: [Item], target: TargetLanguage, limits: BatchLimits, groupBySource: Bool,
                     preferred: [String] = Locale.preferredLanguages,
                     detect: (String) -> Locale.Language?) -> Plan {
        var plan = Plan()
        // 分组键 → 该组里的句子(保持首次出现的顺序)。
        var order: [String] = []
        var groups: [String: (source: Locale.Language?, target: TargetLanguage, items: [Item])] = [:]
        for item in items {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                plan.skipped.append(item.id)
                continue
            }
            let source = detect(text)
            let resolved = target.resolvedTarget(source: source, preferred: preferred)
            if let source, let language = resolved.localeLanguage, LanguageDetector.same(source, language) {
                plan.skipped.append(item.id)
                continue
            }
            let key = groupBySource ? "\(source?.minimalIdentifier ?? "?")>\(resolved.rawValue)" : resolved.rawValue
            if groups[key] == nil {
                order.append(key)
                groups[key] = (groupBySource ? source : nil, resolved, [])
            }
            groups[key]?.items.append(Item(id: item.id, text: text))
        }
        for key in order {
            guard let group = groups[key] else { continue }
            for slice in split(group.items, limits: limits) {
                plan.chunks.append(Chunk(source: group.source, target: group.target, items: slice))
            }
        }
        return plan
    }

    /// 按句数和总长度切块;总长度包括句子之间的分隔符(`limits.separatorLength`)。
    /// 单句超长时单独成块(交给服务端报错或截断,不在这里丢弃)。
    static func split(_ items: [Item], limits: BatchLimits) -> [[Item]] {
        var result: [[Item]] = []
        var current: [Item] = []
        var length = 0
        for item in items {
            let itemLength = limits.length(of: item.text)
            if !current.isEmpty, current.count >= limits.maxItems
                || length + limits.separatorLength + itemLength > limits.maxLength {
                result.append(current)
                current = []
                length = 0
            }
            // 块里已有句子时,这一句前面还有一个分隔符。
            length += (current.isEmpty ? 0 : limits.separatorLength) + itemLength
            current.append(item)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
