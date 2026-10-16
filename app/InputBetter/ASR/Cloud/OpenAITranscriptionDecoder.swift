import Foundation

/// OpenAI 兼容的转写接口(`POST {base}/audio/transcriptions`,multipart:file + model + language + prompt)。
/// 兼容 OpenAI(gpt-4o-transcribe / gpt-4o-mini-transcribe / whisper-1)、Groq、本地 whisper 服务等。
/// 非流式:配合 SegmentedSession 使用——听写结束时整段上传一次;字幕按 VAD 分句上传。
/// 为节省费用,不做录音过程中的实时预览。
nonisolated struct OpenAITranscriptionDecoder: SegmentDecoder {
    let baseURL: String
    let apiKey: String
    let model: String

    /// 不做实时预览(每次预览都是一次付费请求)。
    let partialInterval = Double.infinity
    let maxWholeSeconds = 600.0
    let prefersWholeDictation = true

    func decode(_ samples: [Float], options: ASROptions) async throws -> String {
        guard samples.count >= 4_000 else { return "" }
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/audio/transcriptions") else { throw CloudASRError.badURL }

        var form = MultipartForm()
        form.addFile(name: "file", filename: "audio.wav", mimeType: "audio/wav", data: AudioFormats.wav(samples))
        form.addField(name: "model", value: model)
        form.addField(name: "response_format", value: "json")
        if let code = options.language.isoCode { form.addField(name: "language", value: code) }
        if !options.vocabulary.isEmpty { form.addField(name: "prompt", value: options.vocabulary.joined(separator: ", ")) }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.body
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CloudASRError.server(Self.errorMessage(data, status: http.statusCode))
        }
        return (CloudJSON.object(data)?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func errorMessage(_ data: Data, status: Int) -> String {
        let detail = ((CloudJSON.object(data)?["error"] as? [String: Any])?["message"] as? String)
            ?? String(decoding: data.prefix(200), as: UTF8.self)
        return "HTTP \(status) \(detail)".trimmingCharacters(in: .whitespaces)
    }
}

/// multipart/form-data 请求体(RFC 7578):每个部分以 `--boundary` 开头,最后以 `--boundary--` 结束。
nonisolated struct MultipartForm {
    let boundary = "InputBetter-\(UUID().uuidString)"
    private var parts: [Data] = []

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        parts.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)".utf8))
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        var part = Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
        part.append(data)
        parts.append(part)
    }

    var body: Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(part)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
