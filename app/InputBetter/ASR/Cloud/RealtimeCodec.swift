import Foundation

/// 云端流式识别的协议编解码接口。每家服务一个实现,只负责"消息长什么样",
/// 连接、缓冲、超时、重连都由 StreamingCloudSession 统一处理。
/// 编码函数不改变状态;`parse` 可以维护去重等解析状态(接收循环持有自己的副本)。
nonisolated protocol RealtimeCodec: Sendable {
    /// 建立 WebSocket 的请求(地址 + 鉴权头)。
    func makeRequest() throws -> URLRequest
    /// 连接后、发送音频前要发的消息。
    func startMessages() throws -> [URLSessionWebSocketTask.Message]
    /// 是否要等服务端确认(`.ready`)后才发送音频。
    var waitsForReady: Bool { get }
    /// 每个音频包的字节数(16 kHz 16 bit 单声道:3200 = 100 ms)。
    var chunkBytes: Int { get }
    func audioMessage(_ pcm16: Data) throws -> URLSessionWebSocketTask.Message
    /// 结束输入:发送最后的音频(可能为空)和结束标志。
    func finishMessages(lastChunk: Data) throws -> [URLSessionWebSocketTask.Message]
    /// 结束后收到一条定稿就算完成(没有显式"完成"事件的服务)。
    var completesOnFinalAfterFinish: Bool { get }
    mutating func parse(_ message: URLSessionWebSocketTask.Message) -> [CodecEvent]
}

/// 解析出的事件。
nonisolated enum CodecEvent: Equatable, Sendable {
    case ready
    case partial(String)
    case final(String)
    /// 服务端确认本次识别全部结束。
    case completed
    case failure(String)
}

nonisolated enum CloudASRError: LocalizedError {
    case notConfigured(String)
    case badURL
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let name): String(localized: "\(name) 尚未配置 API Key", bundle: .l10n)
        case .badURL: String(localized: "接口地址无效", bundle: .l10n)
        case .timeout: String(localized: "连接云端识别超时", bundle: .l10n)
        case .server(let message): message
        }
    }
}

/// JSON 编码小工具(各编解码器共用)。
nonisolated enum CloudJSON {
    static func string(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func object(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        switch message {
        case .string(let text): object(Data(text.utf8))
        case .data(let data): object(data)
        @unknown default: nil
        }
    }

    static func integer(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? NSNumber { return v.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
