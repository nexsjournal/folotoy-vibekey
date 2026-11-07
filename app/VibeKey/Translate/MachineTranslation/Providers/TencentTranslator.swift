import Foundation

/// 腾讯云机器翻译 TextTranslateBatch(`tmt.tencentcloudapi.com`,版本 2018-03-21,TC3-HMAC-SHA256 签名)。
/// 一句和多句都走批量接口(一条代码路径);源语言 `auto` 由服务端识别。
nonisolated struct TencentTranslator: MachineTranslator {
    let credentials: MTCredentials
    var session: URLSession = .shared
    var now: @Sendable () -> Date = { Date() }
    var provider: TranslationProvider { .tencent }

    static let host = "tmt.tencentcloudapi.com"
    static let action = "TextTranslateBatch"

    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        let request = try Self.makeRequest(texts: texts, target: target, credentials: credentials, now: now())
        let response = try await MTHTTP.send(request, session: session)
        return try Self.parse(response.data, status: response.status, count: texts.count, retryAfter: response.retryAfter)
    }

    static func makeRequest(texts: [String], target: TargetLanguage, credentials: MTCredentials, now: Date) throws -> URLRequest {
        guard let code = TranslationProvider.tencent.code(for: target) else { throw MachineTranslationError.unsupportedLanguage }
        var request = URLRequest(url: URL(string: "https://\(host)/")!, timeoutInterval: MTHTTP.timeout(for: texts))
        request.httpMethod = "POST"
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue("2018-03-21", forHTTPHeaderField: "X-TC-Version")
        let region = credentials.region.isEmpty ? TranslationProvider.tencent.defaultRegion : credentials.region
        request.setValue(region, forHTTPHeaderField: "X-TC-Region")
        request.httpBody = try MTHTTP.body(["Source": "auto", "Target": code, "ProjectId": 0, "SourceTextList": texts] as [String: Any])
        TencentTC3Signer.sign(&request, secretID: credentials.key, secretKey: credentials.secret, service: "tmt", now: now)
        return request
    }

    /// 成功:`{"Response":{"TargetTextList":[…]}}`;失败:`{"Response":{"Error":{"Code":…,"Message":…}}}`(HTTP 仍是 200)。
    static func parse(_ data: Data, status: Int, count: Int, retryAfter: TimeInterval? = nil) throws -> [String] {
        let response = (MTHTTP.json(data) as? [String: Any])?["Response"] as? [String: Any]
        if let error = response?["Error"] as? [String: Any] {
            let code = error["Code"] as? String ?? ""
            throw classify(code: code, message: error["Message"] as? String ?? code, retryAfter: retryAfter)
        }
        guard (200..<300).contains(status) else {
            throw MTHTTP.classify(status: status, message: MTHTTP.snippet(data), retryAfter: retryAfter)
        }
        let results = response?["TargetTextList"] as? [String] ?? []
        guard results.count == count else { throw MachineTranslationError.badResponse }
        return results
    }

    /// 错误码见腾讯云机器翻译「错误码」文档。`FailedOperation.RequestAiLabErr`(内部请求错误,请稍后重试)
    /// 见国际站错误码表;`FailedOperation.RequestTimeout` 文档未列出,按超时归为可重试以防万一。
    static func classify(code: String, message: String, retryAfter: TimeInterval? = nil) -> MachineTranslationError {
        let detail = "\(code) \(message)".trimmingCharacters(in: .whitespaces)
        if code == "AuthFailure.SignatureExpire" { return .clockSkew }
        if code.hasPrefix("AuthFailure") || code == "FailedOperation.UserNotRegistered" || code == "UnauthorizedOperation" {
            return .auth(detail)
        }
        if code.hasPrefix("RequestLimitExceeded") || code == "LimitExceeded" { return .rateLimited(detail, retryAfter: retryAfter) }
        if code == "FailedOperation.NoFreeAmount" || code == "FailedOperation.ServiceIsolate" || code == "FailedOperation.StopUsing"
            || code.hasPrefix("ResourceUnavailable") {
            return .quotaExceeded(detail)
        }
        // 文档里大小写不统一(UnSupportedTargetLanguage / UnsupportedSourceLanguage),按小写比较。
        if code.lowercased().hasPrefix("unsupportedoperation.unsupported") { return .unsupportedLanguage }
        if code.hasPrefix("InternalError") || code == "FailedOperation.RequestAiLabErr" || code == "FailedOperation.RequestTimeout" {
            return .transient(detail)
        }
        return .server(detail)
    }
}
