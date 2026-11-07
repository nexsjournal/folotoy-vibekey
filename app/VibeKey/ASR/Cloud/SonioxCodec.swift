import Foundation

/// Soniox 实时识别(WebSocket:JSON 配置 + 二进制 PCM,结果按 token 返回)。
/// 文档:https://soniox.com/docs/stt/api-reference/websocket-api
/// - 鉴权放在连接的 `Authorization: Bearer` 头里(配置消息里的 api_key 字段已弃用);
/// - 连接后先发配置消息,按发送顺序紧接着发音频即可;Soniox 没有「就绪」消息,收到第一条正常响应时
///   报告 `.ready`(StreamingCloudSession 结束时要等就绪才发结束帧,收到音频后服务端会持续返回响应);
/// - 每条响应的 `tokens` 里:`is_final` 的 token 只出现一次,需要累加;非最终 token 每次整体重发,替换上一次的;
/// - 字幕开启端点检测:说完一句返回特殊 token `<end>`,此前的 token 都已定稿,于是把累加的文本作为一句定稿;
/// - 听写不开端点检测,松开时发空文本帧结束输入,服务端定稿剩余内容后返回 `finished: true` 并关闭连接;
/// - 出错时返回 `error_code` / `error_type` / `error_message` 后立即关闭连接。
nonisolated struct SonioxCodec: RealtimeCodec {
    let apiKey: String
    let model: String
    let options: ASROptions

    let waitsForReady = false
    /// 100 ms 一包(16 kHz 16 bit 单声道)。
    let chunkBytes = 3_200
    let completesOnFinalAfterFinish = false

    static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    /// 已定稿、但还没凑成一句(没遇到 `<end>` / `<fin>`)的文本。
    private var pendingFinal = ""

    init(apiKey: String, model: String, options: ASROptions) {
        self.apiKey = apiKey
        self.model = model
        self.options = options
    }

    func makeRequest() throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func startMessages() throws -> [URLSessionWebSocketTask.Message] {
        var config: [String: Any] = [
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "enable_endpoint_detection": options.purpose == .subtitles,
        ]
        if options.purpose == .subtitles {
            // 字幕希望一句说完尽快定稿(官方给的低延迟起点值)。
            config["max_endpoint_delay_ms"] = 1_500
        }
        if let hint = Self.languageHint(options.language) { config["language_hints"] = [hint] }
        let terms = options.vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !terms.isEmpty { config["context"] = ["terms": Array(terms.prefix(100))] }
        return [.string(try CloudJSON.string(config))]
    }

    func audioMessage(_ pcm16: Data) throws -> URLSessionWebSocketTask.Message { .data(pcm16) }

    /// 补发最后的音频,再发空文本帧表示输入结束(空的二进制帧只是空音频,不表示结束)。
    func finishMessages(lastChunk: Data) throws -> [URLSessionWebSocketTask.Message] {
        (lastChunk.isEmpty ? [] : [.data(lastChunk)]) + [.string("")]
    }

    mutating func parse(_ message: URLSessionWebSocketTask.Message) -> [CodecEvent] {
        guard let object = CloudJSON.object(message) else { return [] }
        if object["error_code"] != nil || object["error_message"] != nil {
            let type = object["error_type"] as? String ?? "\(CloudJSON.integer(object["error_code"]) ?? 0)"
            return [.failure("\(type): \(object["error_message"] as? String ?? "")")]
        }
        var events: [CodecEvent] = [.ready]
        var nonFinal = ""
        for token in object["tokens"] as? [[String: Any]] ?? [] {
            let text = token["text"] as? String ?? ""
            guard token["is_final"] as? Bool == true else {
                nonFinal += text
                continue
            }
            if text == "<end>" || text == "<fin>" {
                events += flushSentence()
            } else {
                pendingFinal += text
            }
        }
        if object["finished"] as? Bool == true {
            return events + flushSentence() + [.completed]
        }
        // 当前这句的实时文本 = 已定稿部分 + 还会变化的部分。
        if !(object["tokens"] as? [Any] ?? []).isEmpty {
            events.append(.partial((pendingFinal + nonFinal).trimmingCharacters(in: .whitespaces)))
        }
        return events
    }

    /// 把累积的定稿文本作为一句交出去。
    private mutating func flushSentence() -> [CodecEvent] {
        let text = pendingFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFinal = ""
        return text.isEmpty ? [.partial("")] : [.final(text), .partial("")]
    }

    /// Soniox 的语言提示代码。粤语没有单独代码(模型列表里只有 zh),不加提示,交给自动识别。
    static func languageHint(_ language: SpeechLanguage) -> String? {
        switch language {
        case .auto, .yue: nil
        default: language.isoCode
        }
    }
}
