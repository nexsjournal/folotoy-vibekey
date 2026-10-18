import Foundation

/// LLM 文字处理:润色、听写翻译、字幕翻译、批量翻译与译文润色。只依赖 `AppSettings` 读取配置,不关心界面。
/// 翻译类调用都可以指定模型(字幕条「翻译方式」里可以另选模型),空字符串 = 跟随 设置 › AI 服务 的默认模型。
@MainActor
final class TextProcessor {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    private func client(model: String = "") -> LLMClient? {
        guard settings.llmConfigured else { return nil }
        return LLMClient(config: .init(baseURL: settings.llmBaseURL, apiKey: settings.llmAPIKey,
                                       model: model.isEmpty ? settings.llmModel : model))
    }

    var isAvailable: Bool { settings.llmConfigured }

    func polish(_ text: String) async throws -> String {
        guard let client = client(model: settings.polishModel) else { throw LLMError.notConfigured }
        return try await client.complete(system: Prompts.polish(vocabulary: settings.vocabularyTerms), user: text)
    }

    /// 听写翻译(会顺带修正识别错误、去口水词)。
    func translate(_ text: String, to target: TargetLanguage, model: String = "") async throws -> String {
        guard let client = client(model: model) else { throw LLMError.notConfigured }
        let system = Prompts.translateDictation(to: target, vocabulary: settings.vocabularyTerms)
        return try await client.complete(system: system, user: text)
    }

    /// 字幕翻译(流式):带最近几行原文和译文作为上下文(修正识别错误、保持术语一致)。
    /// 每次产出到目前为止的译文,字幕条边生成边显示。超时较短(两段数据之间 10 秒)。
    func translateSubtitle(_ line: String, context: [(source: String, translation: String?)],
                           to target: TargetLanguage, model: String = "") throws -> AsyncThrowingStream<String, Error> {
        guard var client = client(model: model) else { throw LLMError.notConfigured }
        client.timeout = 10
        return client.stream(
            system: Prompts.translateSubtitle(to: target, vocabulary: settings.vocabularyTerms),
            user: Prompts.subtitleUser(current: line, context: context),
            temperature: 0.2)
    }

    /// 批量翻译(字幕记录窗口):一次请求翻译带编号的若干句,按编号取回。句数对不上时抛出 `.empty`,由调用方逐句重试。
    func translateBatch(_ lines: [String], context: [(source: String, translation: String?)],
                        to target: TargetLanguage, model: String = "") async throws -> [String] {
        guard var client = client(model: model) else { throw LLMError.notConfigured }
        client.timeout = 60
        let reply = try await client.complete(system: Prompts.translateBatch(to: target, vocabulary: settings.vocabularyTerms),
                                              user: Prompts.numberedUser(lines, context: context))
        guard let result = NumberedLines.parse(reply, count: lines.count) else { throw LLMError.empty }
        return result
    }

    /// 润色已有译文(字幕记录窗口的「AI 润色」):结合上下文修正识别错误和生硬的机器译文。
    /// `items` 是要润色的(原文, 译文),返回同样条数的新译文;句数对不上时抛出 `.empty`。
    func refineTranslations(_ items: [(source: String, translation: String)], context: [(source: String, translation: String?)],
                            to target: TargetLanguage, model: String = "") async throws -> [String] {
        guard var client = client(model: model) else { throw LLMError.notConfigured }
        client.timeout = 60
        let reply = try await client.complete(system: Prompts.refineTranslations(to: target, vocabulary: settings.vocabularyTerms),
                                              user: Prompts.refineUser(items, context: context))
        guard let result = NumberedLines.parse(reply, count: items.count) else { throw LLMError.empty }
        return result
    }
}
