import Foundation

/// 百度翻译开放平台通用翻译:`POST https://fanyi-api.baidu.com/api/trans/vip/translate`(表单)。
/// 签名 sign = MD5(appid + q + salt + 密钥);多句用换行拼成一个 q,结果按行返回(每行带回原文 `src`)。
/// 标准版 1 QPS(BatchLimits.minInterval),长度按 UTF-8 字节计算,拼接用的换行也计入长度(BatchLimits.separatorLength)。
nonisolated struct BaiduTranslator: MachineTranslator {
    let credentials: MTCredentials
    var session: URLSession = .shared
    var provider: TranslationProvider { .baidu }

    static let endpoint = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!

    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String] {
        let salt = String(Int.random(in: 10_000_000...99_999_999))
        let request = try Self.makeRequest(texts: texts, target: target, credentials: credentials, salt: salt)
        let response = try await MTHTTP.send(request, session: session)
        return try Self.parse(response.data, status: response.status, sources: Self.lines(texts), retryAfter: response.retryAfter)
    }

    static func sign(appID: String, query: String, salt: String, secret: String) -> String {
        SigningCrypto.md5Hex(appID + query + salt + secret)
    }

    /// 实际发出的每一行:句子里不能再有换行(换行是句子分隔符)。parse 回配原文时用同一份。
    static func lines(_ texts: [String]) -> [String] {
        texts.map { $0.replacingOccurrences(of: "\n", with: " ") }
    }

    static func makeRequest(texts: [String], target: TargetLanguage, credentials: MTCredentials, salt: String) throws -> URLRequest {
        guard let code = TranslationProvider.baidu.code(for: target) else { throw MachineTranslationError.unsupportedLanguage }
        let query = lines(texts).joined(separator: "\n")
        let fields = [
            ("q", query), ("from", "auto"), ("to", code), ("appid", credentials.key), ("salt", salt),
            ("sign", sign(appID: credentials.key, query: query, salt: salt, secret: credentials.secret)),
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: MTHTTP.timeout(for: texts))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    /// 表单编码(application/x-www-form-urlencoded):按 RFC 3986 只保留非保留字符,其余百分号编码(空格是 %20)。
    static func formEncode(_ text: String) -> String {
        SigningCrypto.rfc3986Encode(text)
    }

    /// 成功:`{"trans_result":[{"src":…,"dst":…}]}`;失败:`{"error_code":"54001","error_msg":…}`(HTTP 仍是 200)。
    /// - Parameter sources: 发出的各行原文(`lines(texts)`),用于在条数对不上时按 `src` 回配。
    static func parse(_ data: Data, status: Int, sources: [String], retryAfter: TimeInterval? = nil) throws -> [String] {
        let object = MTHTTP.json(data) as? [String: Any]
        if let raw = object?["error_code"], "\(raw)" != "52000" {
            throw classify(code: "\(raw)", message: object?["error_msg"] as? String ?? "", retryAfter: retryAfter)
        }
        guard (200..<300).contains(status) else {
            throw MTHTTP.classify(status: status, message: MTHTTP.snippet(data), retryAfter: retryAfter)
        }
        let entries = ((object?["trans_result"] as? [[String: Any]]) ?? []).compactMap { entry -> Entry? in
            guard let dst = entry["dst"] as? String else { return nil }
            return Entry(src: entry["src"] as? String ?? "", dst: dst)
        }
        if entries.count == sources.count { return entries.map(\.dst) }
        return try match(entries, to: sources)
    }

    /// 返回的一行:原文和译文。
    struct Entry: Equatable {
        let src: String
        let dst: String
    }

    /// 条数和发出的行数不同(服务端把一句里的特殊分隔符当成换行拆开了,或丢掉 / 多出了某行)时,
    /// 按 `src` 把译文配回原文,结果仍按原文顺序:
    /// 1. 从当前位置起,连续若干条的原文拼起来正好是这一句 → 译文拼起来作为这一句的译文(拆行);
    /// 2. 否则在后面找原文完全相同的一条(跳过多出来的行);
    /// 3. 都找不到说明这一句被吞掉了,抛 `.badResponse`(交给调用方按失败处理,不错位显示)。
    /// 比较时忽略空白(服务端会去掉行首尾空格)。
    static func match(_ entries: [Entry], to sources: [String]) throws -> [String] {
        let keys = entries.map { comparable($0.src) }
        var results: [String] = []
        var cursor = 0
        for source in sources {
            let want = comparable(source)
            var joined = ""
            var parts: [String] = []
            var end = cursor
            while end < entries.count, !keys[end].isEmpty, joined.count < want.count, want.hasPrefix(joined + keys[end]) {
                joined += keys[end]
                parts.append(entries[end].dst)
                end += 1
            }
            if !parts.isEmpty, joined == want {
                results.append(joinParts(parts))
                cursor = end
            } else if let index = keys[cursor...].firstIndex(of: want) {
                results.append(entries[index].dst)
                cursor = index + 1
            } else {
                throw MachineTranslationError.badResponse
            }
        }
        return results
    }

    private static func comparable(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    /// 拼接被拆开的译文:相邻两段都是非 ASCII(中日韩等不用空格分词的文字)时直接相连,否则用空格隔开。
    private static func joinParts(_ parts: [String]) -> String {
        parts.reduce(into: "") { result, part in
            let part = part.trimmingCharacters(in: .whitespaces)
            guard !result.isEmpty else { result = part; return }
            let cjk = !(result.last?.isASCII ?? true) && !(part.first?.isASCII ?? true)
            result += cjk ? part : " " + part
        }
    }

    /// 错误码见百度翻译文档:52001 超时、52002 系统错误、52003 未授权、54001 签名错误、54003 访问频率受限、
    /// 54004 余额不足、54005 长 query 请求频繁、58000 IP 不在白名单、58001 不支持的语言、58002 服务已关闭、90107 认证未通过。
    static func classify(code: String, message: String, retryAfter: TimeInterval? = nil) -> MachineTranslationError {
        let detail = "\(code) \(message)".trimmingCharacters(in: .whitespaces)
        switch code {
        case "52001", "52002": return .transient(detail)
        case "52003", "54001", "58000", "58002", "90107": return .auth(detail)
        case "54003", "54005": return .rateLimited(detail, retryAfter: retryAfter)
        case "54004": return .quotaExceeded(detail)
        case "58001": return .unsupportedLanguage
        default: return .server(detail)
        }
    }
}
