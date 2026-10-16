import Foundation

/// 火山引擎豆包流式语音识别(大模型 v3,`bigmodel_async`)。
/// 帧格式:4 字节头 + [服务端:4 字节序号] + 4 字节大端长度 + 负载(gzip)。
/// - 头字节 0 = 0x11(协议 v1,头长 4);字节 1 = (消息类型 << 4) | 标志;字节 2 = (序列化 << 4) | 压缩;字节 3 = 0。
/// - 客户端:类型 1 = 完整请求(JSON + gzip),类型 2 = 音频(raw + gzip),标志 0b0010 = 最后一包。
/// - 服务端:类型 9 = 结果(标志 bit0 = 带序号,bit1 = 最后一包),类型 15 = 错误(4 字节错误码 + 长度 + 消息)。
/// 结果用 `result_type: full`:每次返回全部 utterances,已定稿(`definite`)的按 end_time 去重后作为 final。
/// 文档:https://www.volcengine.com/docs/6561/1354869
nonisolated struct VolcengineCodec: RealtimeCodec {
    let apiKey: String
    /// X-Api-Resource-Id:2.0 为 volc.seedasr.sauc.duration,1.0 为 volc.bigasr.sauc.duration。
    let resourceID: String
    let options: ASROptions
    let connectID = UUID().uuidString

    let waitsForReady = false
    /// 官方建议 100~200 ms 一包,这里用 200 ms。
    let chunkBytes = 6_400
    let completesOnFinalAfterFinish = false

    /// 已作为 final 发出的句子(按 end_time 去重)。
    private var committedEnds: Set<Int> = []
    private var committedAny = false

    init(apiKey: String, resourceID: String, options: ASROptions) {
        self.apiKey = apiKey
        self.resourceID = resourceID
        self.options = options
    }

    func makeRequest() throws -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        return request
    }

    func startMessages() throws -> [URLSessionWebSocketTask.Message] {
        var req: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "show_utterances": true,
            "result_type": "full",
            // 二遍识别:每句结束后用非流式模型重识别,准确率更高。
            "enable_nonstream": true,
            // 字幕希望句子尽快定稿,听写允许更长的停顿。
            "end_window_size": options.purpose == .subtitles ? 600 : 1_000,
        ]
        if !options.vocabulary.isEmpty {
            let hotwords = options.vocabulary.prefix(100).map { ["word": $0] }
            req["corpus"] = ["context": try CloudJSON.string(["hotwords": hotwords])]
        }
        let payload: [String: Any] = [
            "user": ["uid": "inputbetter"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1],
            "request": req,
        ]
        let json = Data(try CloudJSON.string(payload).utf8)
        return [.data(try Self.frame(type: 1, flags: 0, serialization: 1, payload: json))]
    }

    func audioMessage(_ pcm16: Data) throws -> URLSessionWebSocketTask.Message {
        .data(try Self.frame(type: 2, flags: 0, serialization: 0, payload: pcm16))
    }

    func finishMessages(lastChunk: Data) throws -> [URLSessionWebSocketTask.Message] {
        [.data(try Self.frame(type: 2, flags: 0b0010, serialization: 0, payload: lastChunk))]
    }

    /// 组一个客户端帧(负载 gzip 压缩)。
    static func frame(type: UInt8, flags: UInt8, serialization: UInt8, payload: Data) throws -> Data {
        let body = try Gzip.compress(payload)
        var data = Data([0x11, (type << 4) | flags, (serialization << 4) | 0x01, 0x00])
        data.append(contentsOf: bigEndian(UInt32(body.count)))
        data.append(body)
        return data
    }

    mutating func parse(_ message: URLSessionWebSocketTask.Message) -> [CodecEvent] {
        guard case .data(let data) = message else { return [] }
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] >> 4 == 1 else { return [.failure("Invalid frame")] }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let compressed = bytes[2] & 0x0F == 1
        var offset = headerSize

        if type == 15 {
            // 错误帧:错误码 + 长度 + UTF-8 消息。
            guard bytes.count >= offset + 8 else { return [.failure("Server error")] }
            let code = Self.readUInt32(bytes, offset)
            let length = Int(Self.readUInt32(bytes, offset + 4))
            let start = offset + 8
            let messageData = Data(bytes[start..<min(bytes.count, start + length)])
            let text = (compressed ? (try? Gzip.decompress(messageData)) : messageData).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return [.failure("\(Self.describe(code: code)) (\(code)) \(text)")]
        }
        guard type == 9 else { return [] }
        if flags & 0b0001 != 0 { offset += 4 }  // 序号
        guard bytes.count >= offset + 4 else { return [] }
        let length = Int(Self.readUInt32(bytes, offset))
        offset += 4
        guard length >= 0, bytes.count >= offset + length else { return [.failure("Truncated frame")] }
        var payload = Data(bytes[offset..<(offset + length)])
        if compressed { payload = (try? Gzip.decompress(payload)) ?? Data() }
        let isLast = flags & 0b0010 != 0
        var events: [CodecEvent] = [.ready]

        if let object = CloudJSON.object(payload) {
            let result = (object["result"] as? [String: Any]) ?? (object["result"] as? [[String: Any]])?.first
            let utterances = result?["utterances"] as? [[String: Any]] ?? []
            var pending: [String] = []
            for utterance in utterances {
                guard let text = utterance["text"] as? String, !text.isEmpty else { continue }
                let definite = utterance["definite"] as? Bool == true
                if definite || isLast, let end = CloudJSON.integer(utterance["end_time"]) {
                    // 定稿句子按结束时间去重(full 模式每次都会重复返回之前的句子)。
                    if committedEnds.insert(end).inserted {
                        events.append(.final(text))
                        committedAny = true
                    }
                } else {
                    pending.append(text)
                }
            }
            events.append(.partial(TranscriptText.join(pending)))
            // 最后一包没有分句信息时,用整段文本作为定稿。
            if isLast, utterances.isEmpty, !committedAny, let text = result?["text"] as? String, !text.isEmpty {
                events.append(.final(text))
            }
        }
        if isLast { events.append(.completed) }
        return events
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// 常见错误码说明(其余直接显示服务端消息)。
    static func describe(code: UInt32) -> String {
        switch code {
        case 45000001: String(localized: "请求参数无效", bundle: .l10n)
        case 45000002: String(localized: "音频为空", bundle: .l10n)
        case 45000081: String(localized: "等待音频超时", bundle: .l10n)
        case 45000151: String(localized: "音频格式不正确", bundle: .l10n)
        case 55000031: String(localized: "服务繁忙", bundle: .l10n)
        default: String(localized: "火山引擎识别失败", bundle: .l10n)
        }
    }
}
