import Foundation

/// 火山引擎机器翻译 TranslateText:`POST https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01`,
/// AK/SK 签名(VolcengineSigner,地域 cn-north-1、服务 translate),一次最多 8 句(BatchLimits)。
nonisolated struct VolcengineTranslator: MachineTranslator {
    let credentials: MTCredentials
    var session: URLSession = .shared
    var now: @Sendable () -> Date = { Date() }
    var provider: TranslationProvider { .volcengine }

    static let region = "cn-north-1"
    static let service = "translate"

    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        let request = try Self.makeRequest(texts: texts, target: target, credentials: credentials, now: now())
        let response = try await MTHTTP.send(request, session: session)
        return try Self.parse(response.data, status: response.status, count: texts.count, retryAfter: response.retryAfter)
    }

    static func makeRequest(texts: [String], target: TargetLanguage, credentials: MTCredentials, now: Date) throws -> URLRequest {
        guard let code = TranslationProvider.volcengine.code(for: target) else { throw MachineTranslationError.unsupportedLanguage }
        var request = URLRequest(url: URL(string: "https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01")!,
                                 timeoutInterval: MTHTTP.timeout(for: texts))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MTHTTP.body(["TargetLanguage": code, "TextList": texts])
        VolcengineSigner.sign(&request, accessKey: credentials.key, secretKey: credentials.secret,
                              region: region, service: service, now: now)
        return request
    }

    /// 成功:`{"TranslationList":[{"Translation":…}],"ResponseMetadata":{…}}`;
    /// 失败:`ResponseMetadata.Error.{Code,Message}`(HTTP 状态可能仍是 200)。
    static func parse(_ data: Data, status: Int, count: Int, retryAfter: TimeInterval? = nil) throws -> [String] {
        let object = MTHTTP.json(data) as? [String: Any]
        let metadata = object?["ResponseMetadata"] as? [String: Any]
        if let error = metadata?["Error"] as? [String: Any] {
            let code = (error["Code"] as? String) ?? String(describing: error["CodeN"] ?? "")
            throw classify(code: code, message: error["Message"] as? String ?? code, retryAfter: retryAfter)
        }
        guard (200..<300).contains(status) else {
            throw MTHTTP.classify(status: status, message: MTHTTP.snippet(data), retryAfter: retryAfter)
        }
        let results = (object?["TranslationList"] as? [[String: Any]])?.compactMap { $0["Translation"] as? String } ?? []
        guard results.count == count else { throw MachineTranslationError.badResponse }
        return results
    }

    /// 火山的错误码:翻译服务自己的错误是负数字符串(-400 参数错误、-401 / -403 鉴权与权限、-404 / -408 服务端暂时
    /// 找不到资源或超时、-415 不支持的语言对、-429 限流、-500 内部错误),网关层的是英文名
    /// (SignatureDoesNotMatch、InvalidAccessKey、InvalidTimestamp、AccessDenied、FlowLimitExceeded……),按关键词归类。
    /// 关键词的判断顺序有讲究:额度类(如 QuotaLimitExceeded)要先于 limit 判断,否则会被当成可重试的限流。
    static func classify(code: String, message: String, retryAfter: TimeInterval? = nil) -> MachineTranslationError {
        let detail = "\(code) \(message)".trimmingCharacters(in: .whitespaces)
        switch code {
        case "-400": return .server(detail)
        case "-401", "-403": return .auth(detail)
        case "-404", "-408", "-500": return .transient(detail)
        case "-415": return .unsupportedLanguage
        case "-429": return .rateLimited(detail, retryAfter: retryAfter)
        default: break
        }
        let lower = code.lowercased()
        if lower.contains("timestamp") || lower.contains("expired") { return .clockSkew }
        if lower.contains("signature") || lower.contains("accesskey") || lower.contains("accessdenied")
            || lower.contains("unauthorized") || lower.contains("credential") { return .auth(detail) }
        if lower.contains("quota") || lower.contains("balance") || lower.contains("arrear") || lower.contains("notopen") {
            return .quotaExceeded(detail)
        }
        if lower.contains("limit") || lower.contains("throttl") { return .rateLimited(detail, retryAfter: retryAfter) }
        if lower.contains("internal") || lower.contains("unavailable") { return .transient(detail) }
        return .server(detail)
    }
}
