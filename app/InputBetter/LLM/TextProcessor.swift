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

    /// 字幕翻译(流式):带最近几行原文和译文作为上下文(修正识别错误、保持术语一致)。
    /// 每次产出到目前为止的译文,字幕条边生成边显示。超时较短(两段数据之间 10 秒),慢了宁可不显示。
    /// - Parameter draft: 系统翻译的初稿(有的话 LLM 在它基础上修正)。
    func translateSubtitle(_ line: String, context: [(source: String, translation: String?)], draft: String? = nil) throws -> AsyncThrowingStream<String, Error> {
        guard var client else { throw LLMError.notConfigured }
        client.timeout = 10
        return client.stream(
            system: Prompts.translateSubtitle(to: settings.subtitleTarget, vocabulary: settings.vocabularyTerms),
            user: Prompts.subtitleUser(current: line, context: context, draft: draft),
            temperature: 0.2)
    }
}
