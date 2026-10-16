import Foundation

/// ElevenLabs Scribe v2 Realtime(WebSocket + JSON,音频 base64)。
/// - 听写用 `commit_strategy=manual`:松开时发送 `commit: true`,收到 committed_transcript 即完成;
/// - 字幕用 `commit_strategy=vad`:服务端按停顿自动定稿。
/// 文档:https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
nonisolated struct ElevenLabsCodec: RealtimeCodec {
    let apiKey: String
    let model: String
    let options: ASROptions

    let waitsForReady = true
    let chunkBytes = 3_200
    let completesOnFinalAfterFinish = true

    init(apiKey: String, model: String, options: ASROptions) {
        self.apiKey = apiKey
        self.model = model
        self.options = options
    }

    func makeRequest() throws -> URLRequest {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: options.purpose == .subtitles ? "vad" : "manual"),
        ]
        if let code = options.language.isoCode { items.append(URLQueryItem(name: "language_code", value: code)) }
        components.queryItems = items
        guard let url = components.url else { throw CloudASRError.badURL }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    func startMessages() throws -> [URLSessionWebSocketTask.Message] { [] }

    func audioMessage(_ pcm16: Data) throws -> URLSessionWebSocketTask.Message {
        try chunk(pcm16, commit: false)
    }

    func finishMessages(lastChunk: Data) throws -> [URLSessionWebSocketTask.Message] {
        [try chunk(lastChunk, commit: true)]
    }

    private func chunk(_ pcm16: Data, commit: Bool) throws -> URLSessionWebSocketTask.Message {
        .string(try CloudJSON.string([
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm16.base64EncodedString(),
            "commit": commit,
            "sample_rate": 16_000,
        ]))
    }

    mutating func parse(_ message: URLSessionWebSocketTask.Message) -> [CodecEvent] {
        guard let object = CloudJSON.object(message), let type = object["message_type"] as? String else { return [] }
        switch type {
        case "session_started":
            return [.ready]
        case "partial_transcript":
            return [.partial(object["text"] as? String ?? "")]
        case "committed_transcript", "committed_transcript_with_timestamps":
            let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [.partial("")] : [.final(text), .partial("")]
        default:
            // 错误类消息都带 error 字段(auth_error、quota_exceeded、rate_limited……)。
            if let error = object["error"] as? String { return [.failure("\(type): \(error)")] }
            return []
        }
    }
}
