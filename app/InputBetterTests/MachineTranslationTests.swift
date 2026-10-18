import XCTest
@testable import InputBetter

/// 在线机器翻译调用链逐环测试(不联网):
/// MachineTranslationStore(凭据)→ MachineTranslatorFactory → 各家 makeRequest(语言代码、鉴权、签名)→ parse(结果与错误归类)。
/// 签名的哈希原语用公开的标准测试向量(RFC 4231、百度官方文档示例),不用自己的代码生成期望值。
nonisolated final class MachineTranslationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_704_067_200)  // 2024-01-01 00:00:00 UTC

    // MARK: - 语言代码

    func testEveryProviderSupportsEveryTarget() {
        for provider in TranslationProvider.allCases {
            XCTAssertNil(provider.code(for: .auto), "自动要先解析成具体语言")
            for target in TargetLanguage.allCases where target != .auto {
                XCTAssertNotNil(provider.code(for: target), "\(provider) \(target)")
            }
        }
        XCTAssertEqual(TranslationProvider.deepl.code(for: .zhHans), "ZH-HANS")
        XCTAssertEqual(TranslationProvider.deepl.code(for: .en), "EN-US")
        XCTAssertEqual(TranslationProvider.google.code(for: .zhHans), "zh-CN")
        XCTAssertEqual(TranslationProvider.azure.code(for: .zhHant), "zh-Hant")
        XCTAssertEqual(TranslationProvider.tencent.code(for: .zhHant), "zh-TW")
        XCTAssertEqual(TranslationProvider.baidu.code(for: .ja), "jp")
        XCTAssertEqual(TranslationProvider.baidu.code(for: .zhHant), "cht")
        XCTAssertEqual(TranslationProvider.baidu.code(for: .ko), "kor")
    }

    // MARK: - 签名原语

    func testHMACAndMD5Vectors() {
        // RFC 4231 Test Case 2。
        XCTAssertEqual(SigningCrypto.hex(SigningCrypto.hmacSHA256(key: Data("Jefe".utf8), "what do ya want for nothing?")),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(SigningCrypto.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // 百度翻译文档的签名示例。
        XCTAssertEqual(BaiduTranslator.sign(appID: "2015063000000001", query: "apple", salt: "1435660288", secret: "12345678"),
                       "f89f9594663708c1605f3d736d01d2d4")
    }

    // MARK: - 请求构造

    func testDeepLRequest() throws {
        let free = try DeepLTranslator.makeRequest(texts: ["Hello"], target: .zhHans, credentials: MTCredentials(key: "abc:fx"))
        XCTAssertEqual(free.url?.host, "api-free.deepl.com", "免费版 Key 以 :fx 结尾")
        XCTAssertEqual(free.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key abc:fx")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: free.httpBody!) as? [String: Any])
        XCTAssertEqual(body["text"] as? [String], ["Hello"])
        XCTAssertEqual(body["target_lang"] as? String, "ZH-HANS")
        let pro = try DeepLTranslator.makeRequest(texts: ["Hello"], target: .en, credentials: MTCredentials(key: "abc"))
        XCTAssertEqual(pro.url?.host, "api.deepl.com")
    }

    func testGoogleRequest() throws {
        let request = try GoogleTranslator.makeRequest(texts: ["a", "b"], target: .zhHans, credentials: MTCredentials(key: "KEY"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-goog-api-key"), "KEY", "Key 放在请求头")
        XCTAssertEqual(request.url?.absoluteString, "https://translation.googleapis.com/language/translate/v2", "URL 里不带 Key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["q"] as? [String], ["a", "b"])
        XCTAssertEqual(body["target"] as? String, "zh-CN")
        XCTAssertEqual(body["format"] as? String, "text", "按纯文本返回,不做 HTML 转义")
    }

    func testAzureRequest() throws {
        let global = try AzureTranslator.makeRequest(texts: ["a"], target: .zhHans, credentials: MTCredentials(key: "K"))
        XCTAssertNil(global.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region"), "全局资源不带区域头")
        XCTAssertTrue(global.url!.absoluteString.contains("to=zh-Hans"))
        let regional = try AzureTranslator.makeRequest(texts: ["a"], target: .en, credentials: MTCredentials(key: "K", region: "eastasia"))
        XCTAssertEqual(regional.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region"), "eastasia")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: regional.httpBody!) as? [[String: String]])
        XCTAssertEqual(body, [["Text": "a"]])
    }

    func testVolcengineSignedRequest() throws {
        let credentials = MTCredentials(key: "AKID", secret: "SECRET")
        let request = try VolcengineTranslator.makeRequest(texts: ["Hello"], target: .zhHans, credentials: credentials, now: now)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Date"), "20240101T000000Z")
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix("HMAC-SHA256 Credential=AKID/20240101/cn-north-1/translate/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature="))
        XCTAssertEqual(auth.split(separator: "=").last?.count, 64)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Content-Sha256"), SigningCrypto.sha256Hex(request.httpBody!))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["TargetLanguage"] as? String, "zh")
        XCTAssertEqual(VolcengineSigner.canonicalQuery(request.url!), "Action=TranslateText&Version=2020-06-01")
        // 同样输入同样签名;密钥不同签名不同。
        let again = try VolcengineTranslator.makeRequest(texts: ["Hello"], target: .zhHans, credentials: credentials, now: now)
        XCTAssertEqual(again.value(forHTTPHeaderField: "Authorization"), auth)
        let other = try VolcengineTranslator.makeRequest(texts: ["Hello"], target: .zhHans, credentials: MTCredentials(key: "AKID", secret: "X"), now: now)
        XCTAssertNotEqual(other.value(forHTTPHeaderField: "Authorization"), auth)
    }

    func testTencentSignedRequest() throws {
        let request = try TencentTranslator.makeRequest(texts: ["Hello", "World"], target: .zhHans,
                                                        credentials: MTCredentials(key: "SID", secret: "SKEY"), now: now)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "TextTranslateBatch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Region"), "ap-beijing", "没填地域时用默认地域")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Timestamp"), "1704067200")
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix("TC3-HMAC-SHA256 Credential=SID/2024-01-01/tmt/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature="))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["Source"] as? String, "auto")
        XCTAssertEqual(body["SourceTextList"] as? [String], ["Hello", "World"])
    }

    func testBaiduRequestJoinsLines() throws {
        let request = try BaiduTranslator.makeRequest(texts: ["Hello\nthere", "World"], target: .zhHans,
                                                      credentials: MTCredentials(key: "APP", secret: "SEC"), salt: "123")
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("q=Hello%20there%0AWorld"), "句内换行替换成空格,句子之间用换行分隔")
        XCTAssertTrue(form.contains("from=auto"))
        XCTAssertTrue(form.contains("sign=\(BaiduTranslator.sign(appID: "APP", query: "Hello there\nWorld", salt: "123", secret: "SEC"))"))
    }

    // MARK: - 响应解析与错误归类

    func testParseSuccessResponses() throws {
        XCTAssertEqual(try DeepLTranslator.parse(json(#"{"translations":[{"text":"你好"}]}"#), status: 200, count: 1), ["你好"])
        XCTAssertEqual(try GoogleTranslator.parse(json(#"{"data":{"translations":[{"translatedText":"你好"}]}}"#), status: 200, count: 1), ["你好"])
        XCTAssertEqual(try AzureTranslator.parse(json(#"[{"translations":[{"text":"你好","to":"zh-Hans"}]}]"#), status: 200, count: 1), ["你好"])
        XCTAssertEqual(try VolcengineTranslator.parse(json(#"{"TranslationList":[{"Translation":"你好"}],"ResponseMetadata":{}}"#), status: 200, count: 1), ["你好"])
        XCTAssertEqual(try TencentTranslator.parse(json(#"{"Response":{"TargetTextList":["你好","世界"]}}"#), status: 200, count: 2), ["你好", "世界"])
        XCTAssertEqual(try BaiduTranslator.parse(json(#"{"trans_result":[{"src":"a","dst":"甲"},{"src":"b","dst":"乙"}]}"#), status: 200, sources: ["a", "b"]), ["甲", "乙"])
        XCTAssertThrowsError(try BaiduTranslator.parse(json(#"{"trans_result":[{"src":"a","dst":"甲"}]}"#), status: 200, sources: ["a", "b"])) {
            XCTAssertEqual($0 as? MachineTranslationError, .badResponse, "句数对不上且有一句找不到")
        }
    }

    func testErrorClassification() {
        func error(_ block: () throws -> [String]) -> MachineTranslationError? {
            do { _ = try block(); return nil } catch { return error as? MachineTranslationError }
        }
        XCTAssertEqual(error { try DeepLTranslator.parse(json(#"{"message":"Quota exceeded"}"#), status: 456, count: 1) }, .quotaExceeded("Quota exceeded"))
        XCTAssertEqual(error { try DeepLTranslator.parse(json(#"{"message":"Forbidden"}"#), status: 403, count: 1) }, .auth("Forbidden"))
        XCTAssertEqual(error { try GoogleTranslator.parse(json(#"{"error":{"code":400,"message":"API key not valid."}}"#), status: 400, count: 1) },
                       .auth("API key not valid."))
        XCTAssertEqual(error { try AzureTranslator.parse(json(#"{"error":{"code":429001,"message":"slow down"}}"#), status: 429, count: 1) },
                       .rateLimited("slow down"))
        XCTAssertEqual(error { try VolcengineTranslator.parse(json(#"{"ResponseMetadata":{"Error":{"Code":"SignatureDoesNotMatch","Message":"bad"}}}"#), status: 401, count: 1) }?.abortsBatch, true)
        XCTAssertEqual(error { try TencentTranslator.parse(json(#"{"Response":{"Error":{"Code":"AuthFailure.SignatureExpire","Message":"x"}}}"#), status: 200, count: 1) }, .clockSkew)
        XCTAssertEqual(error { try TencentTranslator.parse(json(#"{"Response":{"Error":{"Code":"RequestLimitExceeded","Message":"x"}}}"#), status: 200, count: 1) }?.isRetryable, true)
        XCTAssertEqual(error { try BaiduTranslator.parse(json(#"{"error_code":"54003","error_msg":"Invalid Access Limit"}"#), status: 200, sources: ["a"]) }?.isRetryable, true)
        XCTAssertEqual(error { try BaiduTranslator.parse(json(#"{"error_code":52003,"error_msg":"UNAUTHORIZED USER"}"#), status: 200, sources: ["a"]) }?.abortsBatch, true)
        XCTAssertEqual(MTHTTP.classify(status: 503, message: "down").isRetryable, true)
    }

    func testMoreErrorClassification() {
        func error(_ block: () throws -> [String]) -> MachineTranslationError? {
            do { _ = try block(); return nil } catch { return error as? MachineTranslationError }
        }
        func volc(_ code: String) -> MachineTranslationError {
            VolcengineTranslator.classify(code: code, message: "m")
        }
        // 火山:负数错误码与关键词(额度类先于 limit 判断)。
        XCTAssertEqual(volc("-400"), .server("-400 m"))
        XCTAssertEqual(volc("-401"), .auth("-401 m"))
        XCTAssertEqual(volc("-403"), .auth("-403 m"))
        XCTAssertEqual(volc("-404"), .transient("-404 m"))
        XCTAssertEqual(volc("-408"), .transient("-408 m"))
        XCTAssertEqual(volc("-415"), .unsupportedLanguage)
        XCTAssertEqual(volc("-429"), .rateLimited("-429 m"))
        XCTAssertEqual(volc("-500"), .transient("-500 m"))
        XCTAssertEqual(volc("QuotaLimitExceeded"), .quotaExceeded("QuotaLimitExceeded m"), "额度类不能被当成限流")
        XCTAssertEqual(volc("FlowLimitExceeded"), .rateLimited("FlowLimitExceeded m"))
        XCTAssertEqual(volc("InvalidTimestamp"), .clockSkew)
        // 微软:只有 403001 是额度,403000 是鉴权;400035/400036 是语言无效。
        func azure(_ code: Int, _ status: Int) -> MachineTranslationError? {
            error { try AzureTranslator.parse(json(#"{"error":{"code":\#(code),"message":"m"}}"#), status: status, count: 1) }
        }
        XCTAssertEqual(azure(401000, 401), .auth("m"))
        XCTAssertEqual(azure(403000, 403), .auth("m"))
        XCTAssertEqual(azure(403001, 403), .quotaExceeded("m"))
        XCTAssertEqual(azure(400035, 400), .unsupportedLanguage)
        XCTAssertEqual(azure(400036, 400), .unsupportedLanguage)
        // 腾讯。
        XCTAssertEqual(TencentTranslator.classify(code: "FailedOperation.RequestTimeout", message: "m"), .transient("FailedOperation.RequestTimeout m"))
        XCTAssertEqual(TencentTranslator.classify(code: "FailedOperation.RequestAiLabErr", message: "m"), .transient("FailedOperation.RequestAiLabErr m"))
        XCTAssertEqual(TencentTranslator.classify(code: "InternalError.BackendTimeout", message: "m"), .transient("InternalError.BackendTimeout m"))
        XCTAssertEqual(TencentTranslator.classify(code: "FailedOperation.NoFreeAmount", message: "m"), .quotaExceeded("FailedOperation.NoFreeAmount m"))
        XCTAssertEqual(TencentTranslator.classify(code: "FailedOperation.StopUsing", message: "m").abortsBatch, true)
        XCTAssertEqual(TencentTranslator.classify(code: "UnsupportedOperation.UnSupportedTargetLanguage", message: "m"), .unsupportedLanguage)
        // DeepL:429 限流、529 高负载都可重试;Google 403 dailyLimitExceeded 是额度。
        XCTAssertEqual(error { try DeepLTranslator.parse(json(#"{"message":"Too many requests"}"#), status: 429, count: 1) }, .rateLimited("Too many requests"))
        XCTAssertEqual(error { try DeepLTranslator.parse(json(#"{"message":"busy"}"#), status: 529, count: 1) }?.isRetryable, true)
        XCTAssertEqual(error { try GoogleTranslator.parse(json(#"{"error":{"code":403,"message":"Daily Limit Exceeded","errors":[{"reason":"dailyLimitExceeded"}]}}"#), status: 403, count: 1) },
                       .quotaExceeded("Daily Limit Exceeded"))
        XCTAssertEqual(error { try GoogleTranslator.parse(json(#"{"error":{"code":403,"message":"slow","errors":[{"reason":"userRateLimitExceeded"}]}}"#), status: 403, count: 1) },
                       .rateLimited("slow"))
        // 百度。
        XCTAssertEqual(BaiduTranslator.classify(code: "54004", message: "m"), .quotaExceeded("54004 m"))
        XCTAssertEqual(BaiduTranslator.classify(code: "58001", message: "m"), .unsupportedLanguage)
        // 通用状态码:408 / 425 可重试,400 不重试。
        XCTAssertEqual(MTHTTP.classify(status: 408, message: ""), .transient("HTTP 408"))
        XCTAssertEqual(MTHTTP.classify(status: 425, message: "x"), .transient("x"))
        XCTAssertEqual(MTHTTP.classify(status: 400, message: "bad").isRetryable, false)
    }

    // MARK: - Retry-After 与超时

    func testRetryAfterParsing() {
        let date = Date(timeIntervalSince1970: 1_445_412_480)  // Wed, 21 Oct 2015 07:28:00 GMT
        XCTAssertEqual(MTHTTP.retryAfter("120"), 120)
        XCTAssertEqual(MTHTTP.retryAfter(" 0 "), 0)
        XCTAssertNil(MTHTTP.retryAfter("-1"))
        XCTAssertNil(MTHTTP.retryAfter("soon"))
        XCTAssertNil(MTHTTP.retryAfter(nil))
        XCTAssertEqual(MTHTTP.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: date.addingTimeInterval(-30)), 30)
        XCTAssertEqual(MTHTTP.retryAfter("Wednesday, 21-Oct-15 07:28:00 GMT", now: date.addingTimeInterval(-5)), 5, "RFC 850 旧格式")
        XCTAssertEqual(MTHTTP.retryAfter("Wed Oct 21 07:28:00 2015", now: date.addingTimeInterval(-7)), 7, "asctime 旧格式")
        XCTAssertEqual(MTHTTP.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: date.addingTimeInterval(60)), 0, "已经过去的时间不用等")
    }

    func testRateLimitCarriesRetryAfter() {
        func error(_ block: () throws -> [String]) -> MachineTranslationError? {
            do { _ = try block(); return nil } catch { return error as? MachineTranslationError }
        }
        XCTAssertEqual(error { try DeepLTranslator.parse(json(#"{"message":"slow"}"#), status: 429, count: 1, retryAfter: 5) },
                       .rateLimited("slow", retryAfter: 5))
        XCTAssertEqual(error { try AzureTranslator.parse(json(#"{"error":{"code":429001,"message":"slow"}}"#), status: 429, count: 1, retryAfter: 3) },
                       .rateLimited("slow", retryAfter: 3))
        XCTAssertEqual(error { try GoogleTranslator.parse(json(#"{"error":{"code":429,"message":"slow"}}"#), status: 429, count: 1, retryAfter: 2) },
                       .rateLimited("slow", retryAfter: 2))
        XCTAssertEqual(error { try VolcengineTranslator.parse(json(#"{"ResponseMetadata":{"Error":{"Code":"-429","Message":"m"}}}"#), status: 429, count: 1, retryAfter: 4) },
                       .rateLimited("-429 m", retryAfter: 4))
        XCTAssertNotEqual(MachineTranslationError.rateLimited("x", retryAfter: 1), .rateLimited("x"), "Equatable 区分等待时间")
    }

    func testTimeoutScalesWithRequestSize() throws {
        XCTAssertEqual(MTHTTP.timeout(forCharacters: 0), 10)
        XCTAssertEqual(MTHTTP.timeout(forCharacters: 500), 11)
        XCTAssertEqual(MTHTTP.timeout(forCharacters: 5_000), 20)
        XCTAssertEqual(MTHTTP.timeout(forCharacters: 1_000_000), 30, "最多 30 秒")
        let long = String(repeating: "a", count: 2_500)
        let request = try GoogleTranslator.makeRequest(texts: [long, long], target: .zhHans, credentials: MTCredentials(key: "K"))
        XCTAssertEqual(request.timeoutInterval, 20)
        let short = try DeepLTranslator.makeRequest(texts: ["Hi"], target: .zhHans, credentials: MTCredentials(key: "K"))
        XCTAssertEqual(short.timeoutInterval, 10, accuracy: 0.01)
    }

    // MARK: - 百度按原文回配

    func testBaiduRematchesBySource() throws {
        func entries(_ pairs: [(String, String)]) -> Data {
            let items = pairs.map { ["src": $0.0, "dst": $0.1] }
            return try! JSONSerialization.data(withJSONObject: ["trans_result": items])
        }
        // 拆行:一句被服务端拆成两行,译文拼回这一句(中文直接相连,英文用空格)。
        XCTAssertEqual(try BaiduTranslator.parse(entries([("Hello", "你好"), ("there", "那里"), ("World", "世界")]), status: 200,
                                                 sources: ["Hello\u{2028}there", "World"]), ["你好那里", "世界"])
        XCTAssertEqual(try BaiduTranslator.parse(entries([("你好", "Hi"), ("那里", "there"), ("世界", "World")]), status: 200,
                                                 sources: ["你好\u{2028}那里", "世界"]), ["Hi there", "World"])
        // 多出一行(原文为空):跳过它,其余按原文顺序配上。
        XCTAssertEqual(try BaiduTranslator.parse(entries([("a", "甲"), ("", ""), ("b", "乙")]), status: 200, sources: ["a", "b"]), ["甲", "乙"])
        // 吞行:中间一句没有返回,不能错位,整批按失败处理。
        XCTAssertThrowsError(try BaiduTranslator.parse(entries([("a", "甲"), ("c", "丙")]), status: 200, sources: ["a", "b", "c"])) {
            XCTAssertEqual($0 as? MachineTranslationError, .badResponse)
        }
        // 条数相同时按顺序返回(不比对原文)。
        XCTAssertEqual(try BaiduTranslator.parse(entries([("A", "甲"), ("B", "乙")]), status: 200, sources: ["a", "b"]), ["甲", "乙"])
    }

    func testSplitCountsSeparatorsAndScalars() {
        let items = (0..<3).map { _ in BatchPlanner.Item(id: UUID(), text: "abcd") }
        let noSeparator = BatchLimits(maxItems: 50, maxLength: 8, maxConcurrent: 1, minInterval: 0)
        XCTAssertEqual(BatchPlanner.split(items, limits: noSeparator).map(\.count), [2, 1])
        let newline = BatchLimits(maxItems: 50, maxLength: 8, separatorLength: 1, maxConcurrent: 1, minInterval: 0)
        XCTAssertEqual(BatchPlanner.split(items, limits: newline).map(\.count), [1, 1, 1], "4 + 1(换行)+ 4 = 9 超过 8")
        let exact = BatchLimits(maxItems: 50, maxLength: 9, separatorLength: 1, maxConcurrent: 1, minInterval: 0)
        XCTAssertEqual(BatchPlanner.split(items, limits: exact).map(\.count), [2, 1], "正好等于上限可以放下")
        XCTAssertEqual(TranslationProvider.baidu.limits.separatorLength, 1, "百度用换行拼接")
        XCTAssertEqual(TranslationProvider.google.limits.separatorLength, 0)
        // 一个家庭 emoji 是 1 个字符、5 个码点:按码点计,避免低估长度。
        XCTAssertEqual(noSeparator.length(of: "👨‍👩‍👧"), 5)
    }

    // MARK: - 工厂

    func testFactoryRequiresCompleteCredentials() throws {
        XCTAssertThrowsError(try MachineTranslatorFactory.make(.volcengine, credentials: MTCredentials(key: "AK"))) {
            XCTAssertEqual($0 as? MachineTranslationError, .notConfigured)
        }
        XCTAssertThrowsError(try MachineTranslatorFactory.make(.deepl, credentials: MTCredentials(key: "  "))) {
            XCTAssertEqual($0 as? MachineTranslationError, .notConfigured)
        }
        for provider in TranslationProvider.allCases {
            let credentials = MTCredentials(key: "K", secret: "S", region: "R")
            XCTAssertEqual(try MachineTranslatorFactory.make(provider, credentials: credentials).provider, provider)
        }
    }

    // MARK: - 编码与签名已知答案

    func testRFC3986Encoding() {
        XCTAssertEqual(SigningCrypto.rfc3986Encode("你好 a+b~-._*/="), "%E4%BD%A0%E5%A5%BD%20a%2Bb~-._%2A%2F%3D")
        XCTAssertEqual(BaiduTranslator.formEncode("a b"), "a%20b")
        let url = URL(string: "https://example.com/?b=%E4%BD%A0&a=1+2")!
        XCTAssertEqual(VolcengineSigner.canonicalQuery(url), "a=1%2B2&b=%E4%BD%A0")
    }

    /// 腾讯云「签名方法 v3」官方文档示例(CVM DescribeInstances,时间戳 1551113065)。
    /// 文档里的 SecretKey 是打了码的(`Gu5t9xGARNpq86cd98joQYCN3*******`),用它算不出文档的最终签名,
    /// 所以只核对文档给出的中间值:请求体哈希、规范请求哈希和待签字符串;HMAC 链由 RFC 4231 向量覆盖。
    func testTencentTC3OfficialExample() {
        // 文档的请求体是 Python json.dumps 的输出,「未命名」写成 \u 转义(原样作为字节参与哈希)。
        let body = Data(#"{"Limit": 1, "Filters": [{"Values": ["\u672a\u547d\u540d"], "Name": "instance-name"}]}"#.utf8)
        XCTAssertEqual(SigningCrypto.sha256Hex(body), "35e9c5b0e3ae67532d3c9f17ead6c90222632e5b1ff7f6e89887f1398934f064")
        let canonical = TencentTC3Signer.canonicalRequest(method: "POST", host: "cvm.tencentcloudapi.com", action: "DescribeInstances", body: body)
        XCTAssertEqual(canonical, """
            POST
            /

            content-type:application/json; charset=utf-8
            host:cvm.tencentcloudapi.com
            x-tc-action:describeinstances

            content-type;host;x-tc-action
            35e9c5b0e3ae67532d3c9f17ead6c90222632e5b1ff7f6e89887f1398934f064
            """)
        XCTAssertEqual(SigningCrypto.sha256Hex(canonical), "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84")
        XCTAssertEqual(TencentTC3Signer.stringToSign(timestamp: 1_551_113_065, scope: "2019-02-25/cvm/tc3_request", canonicalRequest: canonical), """
            TC3-HMAC-SHA256
            1551113065
            2019-02-25/cvm/tc3_request
            7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84
            """)
        // 整条签名链(时间戳 → 日期、scope、Authorization 格式)。
        var request = URLRequest(url: URL(string: "https://cvm.tencentcloudapi.com/")!)
        request.httpMethod = "POST"
        request.setValue("DescribeInstances", forHTTPHeaderField: "X-TC-Action")
        request.httpBody = body
        TencentTC3Signer.sign(&request, secretID: "AKIDz8krbsJ5yKBZQpn74WFkmLPx3*******", secretKey: "Gu5t9xGARNpq86cd98joQYCN3*******",
                              service: "cvm", now: Date(timeIntervalSince1970: 1_551_113_065))
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(auth.hasPrefix("TC3-HMAC-SHA256 Credential=AKIDz8krbsJ5yKBZQpn74WFkmLPx3*******/2019-02-25/cvm/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature="))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Timestamp"), "1551113065")
    }

    // MARK: - 凭据

    @MainActor
    func testStoreCompleteness() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ib-mt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "ib-mt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MachineTranslationStore(defaults: defaults, credentials: CredentialStore(url: url))
        XCTAssertTrue(store.configured.isEmpty)
        store.update(.volcengine, MTCredentials(key: " AK ", secret: ""))
        XCTAssertFalse(store.isConfigured(.volcengine), "火山需要 AK 和 SK")
        store.update(.volcengine, MTCredentials(key: " AK ", secret: "SK\n"))
        XCTAssertTrue(store.isConfigured(.volcengine))
        XCTAssertEqual(store.credentials(.volcengine).key, "AK", "去掉粘贴带来的空白")
        store.update(.azure, MTCredentials(key: "K"))
        XCTAssertTrue(store.isConfigured(.azure), "微软全局资源可以不填区域")
        XCTAssertEqual(store.configured, [.azure, .volcengine])
        let reloaded = MachineTranslationStore(defaults: defaults, credentials: CredentialStore(url: url))
        XCTAssertTrue(reloaded.isConfigured(.volcengine), "重新启动后仍在")
        reloaded.remove(.volcengine)
        XCTAssertFalse(reloaded.isConfigured(.volcengine))
        XCTAssertEqual(store.credentials(.tencent).region, "ap-beijing", "腾讯云默认地域")
    }

    func testCredentialFilePermissionsAndNoOpWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ib-cred-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("credentials.json")
        let store = CredentialStore(url: url)
        store.set("v1", for: "k")
        func permissions(_ path: String) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try permissions(url.path), 0o600)
        XCTAssertEqual(try permissions(directory.path), 0o700, "新建的目录只有本人可访问")
        store.set("v2", for: "k")
        XCTAssertEqual(try permissions(url.path), 0o600, "替换后权限不变")
        XCTAssertEqual(CredentialStore(url: url).value(for: "k"), "v2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["credentials.json"], "不留临时文件")
        // 值没变就不写盘:删掉文件后再设同样的值,文件不会被重新创建。
        try FileManager.default.removeItem(at: url)
        store.set("v2", for: "k")
        store.set(nil, for: "missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.set("v3", for: "k")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }
}
