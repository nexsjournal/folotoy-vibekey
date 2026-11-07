import Foundation

/// 阿里云百炼实时语音识别(Fun-ASR / Paraformer realtime,DashScope WebSocket 协议)。
/// 流程:run-task(JSON 文本)→ 等 task-started → 二进制 PCM → finish-task → task-finished。
/// result-generated 里 `sentence_end` 为 false 是中间结果,true 是定稿(按 begin_time 去重)。
/// 文档:https://help.aliyun.com/en/model-studio/fun-asr-client-events
nonisolated struct BailianCodec: RealtimeCodec {
    let apiKey: String
    let model: String
    let region: CloudRegion
    let options: ASROptions
    let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    let waitsForReady = true
    let chunkBytes = 3_200
    let completesOnFinalAfterFinish = false

    private var committedBegins: Set<Int> = []

    init(apiKey: String, model: String, region: CloudRegion, options: ASROptions) {
        self.apiKey = apiKey
        self.model = model
        self.region = region
        self.options = options
    }

    var endpoint: URL {
        switch region {
        case .mainland: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!
        case .international: URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference")!
        }
    }

    func makeRequest() throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func startMessages() throws -> [URLSessionWebSocketTask.Message] {
        var parameters: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16_000,
            // 字幕会长时间连续运行,开启心跳避免静音时被服务端超时断开。
            "heartbeat": options.purpose == .subtitles,
            "max_sentence_silence": options.purpose == .subtitles ? 600 : 1_000,
        ]
        if let code = options.language.isoCode { parameters["language_hints"] = [code] }
        let message: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["task_group": "audio", "task": "asr", "function": "recognition",
                        "model": model, "parameters": parameters, "input": [String: Any]()],
        ]
        return [.string(try CloudJSON.string(message))]
    }

    func audioMessage(_ pcm16: Data) throws -> URLSessionWebSocketTask.Message { .data(pcm16) }

    func finishMessages(lastChunk: Data) throws -> [URLSessionWebSocketTask.Message] {
        var messages: [URLSessionWebSocketTask.Message] = []
        if !lastChunk.isEmpty { messages.append(.data(lastChunk)) }
        let finish: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [String: Any]()],
        ]
        messages.append(.string(try CloudJSON.string(finish)))
        return messages
    }

    mutating func parse(_ message: URLSessionWebSocketTask.Message) -> [CodecEvent] {
        guard let object = CloudJSON.object(message),
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String else { return [] }
        switch event {
        case "task-started":
            return [.ready]
        case "task-finished":
            return [.completed]
        case "task-failed":
            let code = header["error_code"] as? String ?? ""
            let text = header["error_message"] as? String ?? ""
            return [.failure("\(code) \(text)".trimmingCharacters(in: .whitespaces))]
        case "result-generated":
            guard let payload = object["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { return [] }
            // 心跳包不含识别结果。
            if sentence["heartbeat"] as? Bool == true { return [] }
            let text = sentence["text"] as? String ?? ""
            if sentence["sentence_end"] as? Bool == true {
                let begin = CloudJSON.integer(sentence["begin_time"]) ?? committedBegins.count
                guard committedBegins.insert(begin).inserted, !text.isEmpty else { return [.partial("")] }
                return [.final(text), .partial("")]
            }
            return [.partial(text)]
        default:
            return []
        }
    }
}
