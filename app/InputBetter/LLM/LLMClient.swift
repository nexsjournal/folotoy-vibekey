import Foundation

/// OpenAI 兼容的 Chat Completions 客户端(OpenAI、DeepSeek、通义、Ollama、LM Studio 等)。
nonisolated struct LLMClient: Sendable {
    struct Config: Sendable {
        var baseURL: String
        var apiKey: String
        var model: String
    }

    struct Message: Codable, Sendable {
        let role: String
        let content: String
    }

    let config: Config
    var timeout: TimeInterval = 20

    /// 发送一次对话,返回助手回复文本。
    func complete(system: String, user: String, temperature: Double = 0.2) async throws -> String {
        var request = try makeRequest(path: "chat/completions")
        request.httpMethod = "POST"
        let body: [String: Any] = [
            "model": config.model,
            "temperature": temperature,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try Self.parseCompletion(data)
    }

    // MARK: - 内部

    private func makeRequest(path: String) throws -> URLRequest {
        guard let url = OpenAICompatibleAPI.endpoint(config.baseURL, path) else { throw LLMError.badURL }
        var request = OpenAICompatibleAPI.request(url, apiKey: config.apiKey, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        throw LLMError.server(OpenAICompatibleAPI.errorMessage(data, status: http.statusCode))
    }

    /// 解析 Chat Completions 响应,并去掉推理模型输出的 `<think>` 段。
    static func parseCompletion(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable { struct M: Decodable { let content: String? }; let message: M }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard var text = decoded.choices.first?.message.content else { throw LLMError.empty }
        if let range = text.range(of: "</think>") { text = String(text[range.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }
}

nonisolated enum LLMError: LocalizedError {
    case badURL, empty, notConfigured
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badURL: String(localized: "API 地址无效", bundle: .l10n)
        case .empty: String(localized: "模型没有返回内容", bundle: .l10n)
        case .notConfigured: String(localized: "尚未配置 LLM", bundle: .l10n)
        case .server(let message): message
        }
    }
}
