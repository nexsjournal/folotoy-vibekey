import Foundation

/// 微软 Azure AI Translator v3:`POST https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=…`。
/// 鉴权头 `Ocp-Apim-Subscription-Key`;区域资源还要带 `Ocp-Apim-Subscription-Region`(全局资源不带)。
nonisolated struct AzureTranslator: MachineTranslator {
    let credentials: MTCredentials
    var session: URLSession = .shared
    var provider: TranslationProvider { .azure }

    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        let request = try Self.makeRequest(texts: texts, target: target, credentials: credentials)
        let response = try await MTHTTP.send(request, session: session)
        return try Self.parse(response.data, status: response.status, count: texts.count, retryAfter: response.retryAfter)
    }

    static func makeRequest(texts: [String], target: TargetLanguage, credentials: MTCredentials) throws -> URLRequest {
        guard let code = TranslationProvider.azure.code(for: target) else { throw MachineTranslationError.unsupportedLanguage }
        var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
        components.queryItems = [URLQueryItem(name: "api-version", value: "3.0"), URLQueryItem(name: "to", value: code)]
        var request = URLRequest(url: components.url!, timeoutInterval: MTHTTP.timeout(for: texts))
        request.httpMethod = "POST"
        request.setValue(credentials.key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if !credentials.region.isEmpty { request.setValue(credentials.region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MTHTTP.body(texts.map { ["Text": $0] })
        return request
    }

    /// 成功:`[{"translations":[{"text":…}]}]`;失败:`{"error":{"code":401000,"message":…}}`。
    /// 错误码前三位是 HTTP 状态,后三位细分(见 Azure Translator v3 参考的状态码表):
    /// 401xxx 鉴权;403000 操作不被允许(订阅或资源问题,归鉴权)、403001 免费层额度用完,其余 403xxx 按鉴权;
    /// 400035 / 400036 源 / 目标语言无效;429xxx 限流。
    static func parse(_ data: Data, status: Int, count: Int, retryAfter: TimeInterval? = nil) throws -> [String] {
        let json = MTHTTP.json(data)
        guard (200..<300).contains(status) else {
            let error = (json as? [String: Any])?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? MTHTTP.snippet(data)
            let code = (error?["code"] as? Int) ?? 0
            switch code {
            case 403001: throw MachineTranslationError.quotaExceeded(message)
            case 400035, 400036: throw MachineTranslationError.unsupportedLanguage
            default: break
            }
            switch code / 1000 {
            case 401, 403: throw MachineTranslationError.auth(message)
            case 429: throw MachineTranslationError.rateLimited(message, retryAfter: retryAfter)
            default: throw MTHTTP.classify(status: status, message: message, retryAfter: retryAfter)
            }
        }
        let items = json as? [[String: Any]] ?? []
        let results = items.compactMap { ($0["translations"] as? [[String: Any]])?.first?["text"] as? String }
        guard results.count == count else { throw MachineTranslationError.badResponse }
        return results
    }
}
