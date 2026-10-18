import Foundation

/// 腾讯云 API 3.0 签名(TC3-HMAC-SHA256):
/// - 规范请求 = 方法 \n / \n 空查询串 \n 规范头(content-type、host、x-tc-action 小写)\n 签名头列表 \n 请求体 SHA256;
/// - 待签字符串 = "TC3-HMAC-SHA256" \n 时间戳 \n 日期/服务/tc3_request \n 规范请求的 SHA256;
/// - 签名密钥 = HMAC(HMAC(HMAC("TC3" + SecretKey, 日期), 服务), "tc3_request")。
/// 服务端要求时间戳与真实时间误差在 5 分钟内(超出返回 AuthFailure.SignatureExpire)。
/// 规范请求和待签字符串拆成单独的函数,测试可以直接对照官方文档示例里的中间值。
nonisolated enum TencentTC3Signer {
    static let contentType = "application/json; charset=utf-8"
    static let signedHeaders = "content-type;host;x-tc-action"

    /// 给请求加上 X-TC-Timestamp 和 Authorization 头。请求必须已经设置好 URL、body 和 X-TC-Action。
    static func sign(_ request: inout URLRequest, secretID: String, secretKey: String, service: String, now: Date) {
        guard let host = request.url?.host else { return }
        let timestamp = Int(now.timeIntervalSince1970)
        let date = SigningCrypto.utc(Date(timeIntervalSince1970: TimeInterval(timestamp)), "yyyy-MM-dd")
        let canonical = canonicalRequest(method: request.httpMethod ?? "POST", host: host,
                                         action: request.value(forHTTPHeaderField: "X-TC-Action") ?? "",
                                         body: request.httpBody ?? Data())
        let scope = "\(date)/\(service)/tc3_request"
        let toSign = stringToSign(timestamp: timestamp, scope: scope, canonicalRequest: canonical)
        var key = SigningCrypto.hmacSHA256(key: Data("TC3\(secretKey)".utf8), date)
        key = SigningCrypto.hmacSHA256(key: key, service)
        key = SigningCrypto.hmacSHA256(key: key, "tc3_request")
        let signature = SigningCrypto.hex(SigningCrypto.hmacSHA256(key: key, toSign))

        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue("TC3-HMAC-SHA256 Credential=\(secretID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// 规范请求(POST、路径 /、无查询串;Action 按规范转小写)。
    static func canonicalRequest(method: String, host: String, action: String, body: Data) -> String {
        [
            method,
            "/",
            "",
            "content-type:\(contentType)\nhost:\(host)\nx-tc-action:\(action.lowercased())\n",
            signedHeaders,
            SigningCrypto.sha256Hex(body),
        ].joined(separator: "\n")
    }

    static func stringToSign(timestamp: Int, scope: String, canonicalRequest: String) -> String {
        ["TC3-HMAC-SHA256", String(timestamp), scope, SigningCrypto.sha256Hex(canonicalRequest)].joined(separator: "\n")
    }
}
