import Foundation

/// 火山引擎 OpenAPI 签名(HMAC-SHA256,与官方 SDK 的 V4 风格签名一致):
/// - 规范请求 = 方法 \n 路径 \n 排序后的查询串 \n 规范头 \n 签名头列表 \n 请求体 SHA256;
/// - 待签字符串 = "HMAC-SHA256" \n X-Date \n 日期/地域/服务/request \n 规范请求的 SHA256;
/// - 签名密钥 = HMAC(HMAC(HMAC(HMAC(SK, 日期), 地域), 服务), "request")。
/// 时间由调用方传入,便于测试;服务端要求与真实时间误差在几分钟内。
nonisolated enum VolcengineSigner {
    /// 给请求加上 X-Date、X-Content-Sha256、Authorization 头。请求必须已经设置好 URL、方法、Content-Type 和 body。
    static func sign(_ request: inout URLRequest, accessKey: String, secretKey: String,
                     region: String, service: String, now: Date) {
        guard let url = request.url, let host = url.host else { return }
        let body = request.httpBody ?? Data()
        let xDate = SigningCrypto.utc(now, "yyyyMMdd'T'HHmmss'Z'")
        let shortDate = String(xDate.prefix(8))
        let payloadHash = SigningCrypto.sha256Hex(body)
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? "application/json"

        let headers: [(String, String)] = [
            ("content-type", contentType),
            ("host", host),
            ("x-content-sha256", payloadHash),
            ("x-date", xDate),
        ]
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalRequest = [
            request.httpMethod ?? "POST",
            url.path.isEmpty ? "/" : url.path,
            canonicalQuery(url),
            headers.map { "\($0.0):\($0.1)" }.joined(separator: "\n") + "\n",
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign = ["HMAC-SHA256", xDate, scope, SigningCrypto.sha256Hex(canonicalRequest)].joined(separator: "\n")
        var key = SigningCrypto.hmacSHA256(key: Data(secretKey.utf8), shortDate)
        key = SigningCrypto.hmacSHA256(key: key, region)
        key = SigningCrypto.hmacSHA256(key: key, service)
        key = SigningCrypto.hmacSHA256(key: key, "request")
        let signature = SigningCrypto.hex(SigningCrypto.hmacSHA256(key: key, stringToSign))

        request.setValue(xDate, forHTTPHeaderField: "X-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue("HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// 查询参数按名称排序,名称和值按 RFC 3986 编码(只保留字母数字和 -_.~)。
    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(name: String, value: String)] = items.map { (encode($0.name), encode($0.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    private static func encode(_ text: String) -> String {
        SigningCrypto.rfc3986Encode(text)
    }
}
