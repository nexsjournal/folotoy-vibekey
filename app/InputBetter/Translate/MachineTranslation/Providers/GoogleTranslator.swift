import Foundation

/// Google Cloud Translation Basic(v2):`POST https://translation.googleapis.com/language/translate/v2`。
/// API Key 放在请求头 `X-goog-api-key`(Google 推荐的做法,不进 URL,也就不会出现在日志和代理记录里);
/// `format=text` 让结果不做 HTML 转义。
nonisolated struct GoogleTranslator: MachineTranslator {
    let credentials: MTCredentials
    var session: URLSession = .shared
    var provider: TranslationProvider { .google }

    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        let request = try Self.makeRequest(texts: texts, target: target, credentials: credentials)
        let response = try await MTHTTP.send(request, session: session)
        return try Self.parse(response.data, status: response.status, count: texts.count, retryAfter: response.retryAfter)
    }

    static let endpoint = URL(string: "https://translation.googleapis.com/language/translate/v2")!

    static func makeRequest(texts: [String], target: TargetLanguage, credentials: MTCredentials) throws -> URLRequest {
        guard let code = TranslationProvider.google.code(for: target) else { throw MachineTranslationError.unsupportedLanguage }
        var request = URLRequest(url: endpoint, timeoutInterval: MTHTTP.timeout(for: texts))
        request.httpMethod = "POST"
        request.setValue(credentials.key, forHTTPHeaderField: "X-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MTHTTP.body(["q": texts, "target": code, "format": "text"])
        return request
    }

    /// 成功:`{"data":{"translations":[{"translatedText":…}]}}`;
    /// 失败:`{"error":{"code":…,"message":…,"errors":[{"reason":…}]}}`。
    /// `reason` 含 RateLimit → 限流;含 dailyLimit / quota → 额度用完(要先于 403 的鉴权归类判断)。
    static func parse(_ data: Data, status: Int, count: Int, retryAfter: TimeInterval? = nil) throws -> [String] {
        let object = MTHTTP.json(data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = object?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? MTHTTP.snippet(data)
            let reason = ((error?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
            if reason.localizedCaseInsensitiveContains("RateLimit") { throw MachineTranslationError.rateLimited(message, retryAfter: retryAfter) }
            if reason.localizedCaseInsensitiveContains("dailyLimit") || reason.localizedCaseInsensitiveContains("quota") {
                throw MachineTranslationError.quotaExceeded(message)
            }
            // 无效 Key 返回 400 "API key not valid"。
            if status == 400, message.localizedCaseInsensitiveContains("API key") { throw MachineTranslationError.auth(message) }
            throw MTHTTP.classify(status: status, message: message, retryAfter: retryAfter)
        }
        let translations = ((object?["data"] as? [String: Any])?["translations"] as? [[String: Any]]) ?? []
        let results = translations.compactMap { $0["translatedText"] as? String }
        guard results.count == count else { throw MachineTranslationError.badResponse }
        return results
    }
}
