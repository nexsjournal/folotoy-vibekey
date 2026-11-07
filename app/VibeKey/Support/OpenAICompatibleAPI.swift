import Foundation

/// OpenAI 兼容接口的公共部分(LLM 与云端转写共用,只实现一次):
/// 拼接地址、鉴权头、错误信息解析、拉取模型列表(`GET {base}/models`)。
/// OpenAI、DeepSeek、通义千问兼容模式、OpenRouter、Groq、Ollama、LM Studio 都支持这套接口。
nonisolated enum OpenAICompatibleAPI {
    /// `{base}/{path}`:去掉首尾空白和末尾的 `/`,避免出现 `//models`。
    static func endpoint(_ baseURL: String, _ path: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: "\(base)/\(path)"), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// 带鉴权头的请求;Key 为空时不加(本地服务如 Ollama 不需要)。
    static func request(_ url: URL, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// 从错误响应里取出可读的原因(`{"error":{"message":…}}`,取不到就用响应开头)。
    static func errorMessage(_ data: Data, status: Int) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
            ?? (object?["error"] as? String)
            ?? String(decoding: data.prefix(200), as: UTF8.self)
        return "HTTP \(status) \(detail)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 拉取可用模型 ID 列表(按名称排序)。
    static func listModels(baseURL: String, apiKey: String, timeout: TimeInterval = 15) async throws -> [String] {
        guard let url = endpoint(baseURL, "models") else { throw APIError.badURL }
        let (data, response) = try await URLSession.shared.data(for: request(url, apiKey: apiKey, timeout: timeout))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.server(errorMessage(data, status: http.statusCode))
        }
        return try parseModelList(data)
    }

    /// 解析 `{"data":[{"id":…}]}`(OpenAI 格式);部分服务直接返回数组或用 `models` 字段,也一并兼容。
    static func parseModelList(_ data: Data) throws -> [String] {
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = json as? [String: Any]
        guard let items = (object?["data"] ?? object?["models"]) as? [Any] ?? json as? [Any] else {
            throw APIError.unexpectedResponse
        }
        let ids = items.compactMap { item -> String? in
            if let id = item as? String { return id }
            let entry = item as? [String: Any]
            return (entry?["id"] ?? entry?["name"]) as? String
        }
        return Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    enum APIError: LocalizedError {
        case badURL
        case unexpectedResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badURL: String(localized: "接口地址无效", bundle: .l10n)
            case .unexpectedResponse: String(localized: "接口没有返回模型列表", bundle: .l10n)
            case .server(let message): message
            }
        }
    }
}
