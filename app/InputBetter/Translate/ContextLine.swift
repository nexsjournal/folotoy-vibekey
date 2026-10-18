import Foundation

/// 翻译时给 AI 的上下文:前面一句的原文和已有译文(保持术语一致、理解被切开的半句)。
/// 用值类型而不是元组:要跨进并发任务(批量翻译的任务组、请求闸门)。
nonisolated struct ContextLine: Equatable, Sendable {
    let source: String
    let translation: String?

    /// 转成 TextProcessor / Prompts 使用的元组形式。
    static func tuples(_ lines: [ContextLine]) -> [(source: String, translation: String?)] {
        lines.map { (source: $0.source, translation: $0.translation) }
    }
}
