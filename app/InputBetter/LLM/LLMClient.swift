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

    /// 流式对话(`stream: true`,Server-Sent Events):每收到一段增量就产出一次"到目前为止的完整回复"。
    /// 用于字幕翻译——译文边生成边显示,首字延迟从"整句生成完"降到"第一个词生成出来"。
    /// 推理模型开头的 `<think>…</think>` 段不产出。任务被取消时停止读取并结束。
    func stream(system: String, user: String, temperature: Double = 0.2) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest(path: "chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let body: [String: Any] = [
                        "model": config.model,
                        "temperature": temperature,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user],
                        ],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes.prefix(4_096) { data.append(byte) }
                        throw LLMError.server(OpenAICompatibleAPI.errorMessage(data, status: http.statusCode))
                    }
                    var raw = ""
                    for try await line in bytes.lines {
                        guard let delta = Self.parseStreamLine(line) else { continue }
                        if delta == Self.streamDone { break }
                        raw += delta
                        if let visible = Self.visibleText(raw), !visible.isEmpty { continuation.yield(visible) }
                    }
                    guard let final = Self.visibleText(raw), !final.isEmpty else { throw LLMError.empty }
                    continuation.yield(final)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// SSE 结束标记(`data: [DONE]`)。
    static let streamDone = "\u{0}[DONE]"

    /// 解析一行 SSE:`data: {"choices":[{"delta":{"content":"…"}}]}` → 增量文字;`data: [DONE]` → streamDone;其他行 nil。
    static func parseStreamLine(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return streamDone }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }

    /// 去掉推理模型的思考段:以 `<think>` 开头且还没出现 `</think>` 时返回 nil(暂不显示)。
    static func visibleText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<think>") {
            guard let end = trimmed.range(of: "</think>") else { return nil }
            return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
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
