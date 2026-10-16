import Foundation

/// 听写后处理:润色或翻译。只依赖 `AppSettings` 读取配置,不关心界面。
@MainActor
final class TextProcessor {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    private var client: LLMClient? {
        guard settings.llmConfigured else { return nil }
        return LLMClient(config: .init(baseURL: settings.llmBaseURL, apiKey: settings.llmAPIKey, model: settings.llmModel))
    }

    var isAvailable: Bool { client != nil }

    func polish(_ text: String) async throws -> String {
        guard let client else { throw LLMError.notConfigured }
        return try await client.complete(system: Prompts.polish(vocabulary: settings.vocabularyTerms), user: text)
    }

    func translate(_ text: String) async throws -> String {
        guard let client else { throw LLMError.notConfigured }
        let system = Prompts.translateDictation(to: settings.translateTarget, vocabulary: settings.vocabularyTerms)
        return try await client.complete(system: system, user: text)
    }

    /// 字幕翻译:带最近几行原文和译文作为上下文(修正识别错误、保持术语一致)。超时较短,慢了宁可不显示。
    func translateSubtitle(_ line: String, context: [(source: String, translation: String?)]) async throws -> String {
        guard var client else { throw LLMError.notConfigured }
        client.timeout = 10
        return try await client.complete(
            system: Prompts.translateSubtitle(to: settings.subtitleTarget, vocabulary: settings.vocabularyTerms),
            user: Prompts.subtitleUser(current: line, context: context),
            temperature: 0.2)
    }
}
