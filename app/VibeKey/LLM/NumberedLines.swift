import Foundation

/// 带编号的多行文本(LLM 批量翻译 / 润色的输入输出格式):每行 `[n] 文字`。
/// 解析时容忍模型在前后加说明、在编号行之间换行续写;编号缺失或数量不对返回 nil(调用方改为逐句处理)。
nonisolated enum NumberedLines {
    static func format(_ lines: [String]) -> String {
        lines.enumerated().map { "[\($0.offset + 1)] \($0.element.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
    }

    static func parse(_ text: String, count: Int) -> [String]? {
        var results: [Int: String] = [:]
        var current: Int?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
               let number = Int(line[line.index(after: line.startIndex)..<close]) {
                current = number
                results[number] = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else if let number = current, !line.isEmpty {
                // 编号行之后的续行(模型把一句译文拆成了两行)。
                results[number, default: ""] += " " + line
            }
        }
        let ordered = (1...max(count, 1)).compactMap { results[$0] }
        guard count > 0, ordered.count == count, results.count == count else { return nil }
        return ordered
    }
}
