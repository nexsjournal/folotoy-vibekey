import Foundation

/// DeepL API v2(`POST /v2/translate`,JSON)。
/// 免费版 Key 以 `:fx` 结尾,要用 api-free.deepl.com;专业版用 api.deepl.com。鉴权头 `DeepL-Auth-Key`。
nonisolated struct DeepLTranslator: MachineTranslator {
    let credentials: MTCredentials
    var session: URLSession = .shared
    var provider: TranslationProvider { .deepl }

    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        let request = try Self.makeRequest(texts: texts, target: target, credentials: credentials)
        let response = try await MTHTTP.send(request, session: session)
        return try Self.parse(response.data, status: response.status, count: texts.count, retryAfter: response.retryAfter)
    }

    static func endpoint(for key: String) -> URL {
        key.hasSuffix(":fx") ? URL(string: "https://api-free.deepl.com/v2/translate")! : URL(string: "https://api.deepl.com/v2/translate")!
    }

    static func makeRequest(texts: [String], target: TargetLanguage, credentials: MTCredentials) throws -> URLRequest {
        guard let code = TranslationProvider.deepl.code(for: target) else { throw MachineTranslationError.unsupportedLanguage }
        var request = URLRequest(url: endpoint(for: credentials.key), timeoutInterval: MTHTTP.timeout(for: texts))
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(credentials.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MTHTTP.body(["text": texts, "target_lang": code])
        return request
    }

    /// 成功:`{"translations":[{"text":…}]}`;失败:`{"message":…}`。
    /// 403 鉴权失败、456 额度用完、429 请求太多、529 服务端过载(DeepL 文档:"Too many requests" 的高负载变体,可重试)。
    static func parse(_ data: Data, status: Int, count: Int, retryAfter: TimeInterval? = nil) throws -> [String] {
        let object = MTHTTP.json(data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = object?["message"] as? String ?? MTHTTP.snippet(data)
            switch status {
            case 403: throw MachineTranslationError.auth(message)
            case 456: throw MachineTranslationError.quotaExceeded(message)
            case 529: throw MachineTranslationError.rateLimited(message, retryAfter: retryAfter)
            default: throw MTHTTP.classify(status: status, message: message, retryAfter: retryAfter)
            }
        }
        let results = (object?["translations"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        guard results.count == count else { throw MachineTranslationError.badResponse }
        return results
    }
}
