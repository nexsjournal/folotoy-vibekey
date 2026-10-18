import XCTest
@testable import InputBetter

/// 云端识别调用链逐环测试(不联网):
/// StreamingCloudSession → RealtimeCodec(编码 / 解析)→ Gzip / AudioFormats.pcm16;
/// OpenAITranscriptionDecoder → AudioFormats.wav → MultipartForm;配置与凭据存储。
nonisolated final class CloudASRTests: XCTestCase {
    private let dictation = ASROptions(purpose: .dictation, language: .zh, vocabulary: ["InputBetter"])

    // MARK: - 基础工具

    func testGzipRoundTrip() throws {
        let original = Data(String(repeating: "你好 InputBetter ", count: 200).utf8)
        let compressed = try Gzip.compress(original)
        XCTAssertEqual(Array(compressed.prefix(2)), [0x1F, 0x8B], "必须是 gzip 格式(火山引擎要求)")
        XCTAssertLessThan(compressed.count, original.count)
        XCTAssertEqual(try Gzip.decompress(compressed), original)
    }

    func testPCM16ClampsAndIsLittleEndian() {
        let data = AudioFormats.pcm16([0, 1, -1, 2])
        XCTAssertEqual(data.count, 8)
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        XCTAssertEqual(values, [0, 32767, -32767, 32767])
    }

    func testWavHeader() {
        let wav = AudioFormats.wav([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(wav.count, 44 + 32_000)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
    }

    func testMultipartBodyHasSingleTerminatorAtEnd() {
        var form = MultipartForm()
        form.addField(name: "model", value: "whisper-1")
        form.addFile(name: "file", filename: "a.wav", mimeType: "audio/wav", data: Data([1, 2, 3]))
        let body = String(decoding: form.body, as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("--\(form.boundary)\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(form.boundary)--\r\n"))
        XCTAssertEqual(body.components(separatedBy: "--\(form.boundary)--").count, 2, "结束标记只能出现一次")
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"))
        XCTAssertTrue(form.contentType.contains(form.boundary))
    }

    // MARK: - 火山引擎

    /// 组一个服务端结果帧(type 9,带序号,gzip JSON)。
    private func volcResponse(_ json: [String: Any], last: Bool = false) throws -> URLSessionWebSocketTask.Message {
        let payload = try Gzip.compress(JSONSerialization.data(withJSONObject: json))
        var bytes: [UInt8] = [0x11, (9 << 4) | (last ? 0b0011 : 0b0001), 0x11, 0x00]
        bytes += [0, 0, 0, 1]  // 序号
        let n = UInt32(payload.count)
        bytes += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        return .data(Data(bytes) + payload)
    }

    func testVolcengineRequestAndFrames() throws {
        let codec = VolcengineCodec(apiKey: "k", resourceID: "volc.seedasr.sauc.duration", options: dictation)
        let request = try codec.makeRequest()
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.seedasr.sauc.duration")

        guard case .data(let start) = try codec.startMessages().first else { return XCTFail("开始消息应为二进制帧") }
        XCTAssertEqual(Array(start.prefix(3)), [0x11, 0x10, 0x11])  // full client request, JSON + gzip
        let length = start[4..<8].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(length, start.count - 8)
        let json = try XCTUnwrap(CloudJSON.object(try Gzip.decompress(start.suffix(from: 8))))
        XCTAssertNotNil(json["audio"])

        guard case .data(let last) = try codec.finishMessages(lastChunk: Data([0, 0])).first else { return XCTFail() }
        XCTAssertEqual(last[1], 0x22, "最后一包:音频帧 + 结束标志")
    }

    func testVolcengineParseDedupesDefiniteUtterances() throws {
        var codec = VolcengineCodec(apiKey: "k", resourceID: "r", options: dictation)
        let first = codec.parse(try volcResponse(["result": ["text": "你好世界", "utterances": [
            ["text": "你好，", "definite": true, "end_time": 800],
            ["text": "世界", "definite": false, "end_time": 1200],
        ]]]))
        XCTAssertEqual(first, [.ready, .final("你好，"), .partial("世界")])
        // full 模式会重复返回已定稿的句子,不能重复提交。
        let second = codec.parse(try volcResponse(["result": ["utterances": [
            ["text": "你好，", "definite": true, "end_time": 800],
            ["text": "世界。", "definite": true, "end_time": 1300],
        ]]], last: true))
        XCTAssertEqual(second, [.ready, .final("世界。"), .partial(""), .completed])
    }

    func testVolcengineErrorFrame() {
        var codec = VolcengineCodec(apiKey: "k", resourceID: "r", options: dictation)
        let message = Data("bad key".utf8)
        var bytes: [UInt8] = [0x11, 0xF0, 0x10, 0x00, 0, 0x2D, 0xC6, 0xC1]  // 错误码 3000001
        bytes += [0, 0, 0, UInt8(message.count)]
        guard case .failure(let text) = codec.parse(.data(Data(bytes) + message)).first else { return XCTFail() }
        XCTAssertTrue(text.contains("3000001"))
        XCTAssertTrue(text.contains("bad key"))
    }

    // MARK: - 阿里云百炼

    func testBailianRunTaskAndParse() throws {
        var codec = BailianCodec(apiKey: "k", model: "fun-asr-realtime", region: .international, options: dictation)
        let request = try codec.makeRequest()
        XCTAssertEqual(request.url?.host, "dashscope-intl.aliyuncs.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        guard case .string(let run) = try codec.startMessages().first,
              let object = CloudJSON.object(Data(run.utf8)),
              let header = object["header"] as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(header["action"] as? String, "run-task")
        let taskID = header["task_id"] as? String
        guard case .string(let finish) = try codec.finishMessages(lastChunk: Data()).last,
              let finishHeader = CloudJSON.object(Data(finish.utf8))?["header"] as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(finishHeader["action"] as? String, "finish-task")
        XCTAssertEqual(finishHeader["task_id"] as? String, taskID, "finish-task 必须带同一个 task_id")

        func event(_ name: String, sentence: [String: Any]? = nil) throws -> URLSessionWebSocketTask.Message {
            var json: [String: Any] = ["header": ["event": name]]
            if let sentence { json["payload"] = ["output": ["sentence": sentence]] }
            return .string(try CloudJSON.string(json))
        }
        XCTAssertEqual(codec.parse(try event("task-started")), [.ready])
        XCTAssertEqual(codec.parse(try event("result-generated", sentence: ["text": "今天", "sentence_end": false, "begin_time": 0])), [.partial("今天")])
        XCTAssertEqual(codec.parse(try event("result-generated", sentence: ["text": "今天天气好。", "sentence_end": true, "begin_time": 0])),
                       [.final("今天天气好。"), .partial("")])
        XCTAssertEqual(codec.parse(try event("result-generated", sentence: ["text": "今天天气好。", "sentence_end": true, "begin_time": 0])),
                       [.partial("")], "同一句不能重复提交")
        XCTAssertEqual(codec.parse(try event("result-generated", sentence: ["heartbeat": true])), [])
        XCTAssertEqual(codec.parse(try event("task-finished")), [.completed])
    }

    // MARK: - ElevenLabs

    func testElevenLabsMessages() throws {
        var codec = ElevenLabsCodec(apiKey: "k", model: "scribe_v2_realtime", options: dictation)
        let request = try codec.makeRequest()
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "k")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "commit_strategy" }?.value, "manual", "听写由松开按键决定何时定稿")

        guard case .string(let last) = try codec.finishMessages(lastChunk: Data([1, 0])).first,
              let object = CloudJSON.object(Data(last.utf8)) else { return XCTFail() }
        XCTAssertEqual(object["commit"] as? Bool, true)
        XCTAssertEqual(object["audio_base_64"] as? String, Data([1, 0]).base64EncodedString())

        XCTAssertEqual(codec.parse(.string(#"{"message_type":"session_started"}"#)), [.ready])
        XCTAssertEqual(codec.parse(.string(#"{"message_type":"partial_transcript","text":"hel"}"#)), [.partial("hel")])
        XCTAssertEqual(codec.parse(.string(#"{"message_type":"committed_transcript","text":"hello "}"#)), [.final("hello"), .partial("")])
        XCTAssertEqual(codec.parse(.string(#"{"message_type":"auth_error","error":"invalid key"}"#)), [.failure("auth_error: invalid key")])
    }

    // MARK: - Soniox

    func testSonioxRequestAndConfig() throws {
        let codec = SonioxCodec(apiKey: "k", model: "stt-rt-v5", options: dictation)
        let request = try codec.makeRequest()
        XCTAssertEqual(request.url?.absoluteString, "wss://stt-rt.soniox.com/transcribe-websocket")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k", "鉴权放在连接头里,不放在配置消息里")

        guard case .string(let start) = try codec.startMessages().first,
              let config = CloudJSON.object(Data(start.utf8)) else { return XCTFail() }
        XCTAssertEqual(config["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(config["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(CloudJSON.integer(config["sample_rate"]), 16_000)
        XCTAssertEqual(CloudJSON.integer(config["num_channels"]), 1)
        XCTAssertNil(config["api_key"])
        XCTAssertEqual(config["enable_endpoint_detection"] as? Bool, false, "听写由松开按键结束,不按停顿切句")
        XCTAssertEqual(config["language_hints"] as? [String], ["zh"])
        XCTAssertEqual((config["context"] as? [String: Any])?["terms"] as? [String], ["InputBetter"])

        let subtitles = SonioxCodec(apiKey: "k", model: "stt-rt-v5",
                                    options: ASROptions(purpose: .subtitles, language: .yue, vocabulary: []))
        guard case .string(let subStart) = try subtitles.startMessages().first,
              let subConfig = CloudJSON.object(Data(subStart.utf8)) else { return XCTFail() }
        XCTAssertEqual(subConfig["enable_endpoint_detection"] as? Bool, true)
        XCTAssertNil(subConfig["language_hints"], "粤语没有单独的语言代码,交给自动识别")
        XCTAssertNil(subConfig["context"])

        // 结束:先补最后的音频(二进制),再发空文本帧;空的二进制帧不算结束。
        XCTAssertEqual(try codec.finishMessages(lastChunk: Data([1, 0])).map(describe), ["data:0100", "string:"])
        XCTAssertEqual(try codec.finishMessages(lastChunk: Data()).map(describe), ["string:"])
        XCTAssertEqual(describe(try codec.audioMessage(Data([2, 0]))), "data:0200")
    }

    /// WebSocket 消息不是 Equatable,转成「类型:内容」便于比较。
    private func describe(_ message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .data(let data): "data:" + data.map { String(format: "%02x", $0) }.joined()
        case .string(let text): "string:" + text
        @unknown default: "unknown"
        }
    }

    /// token 流:最终 token 只来一次要累加,非最终 token 每次整体替换;<end> 切句,finished 收尾。
    func testSonioxTokenParsing() {
        var codec = SonioxCodec(apiKey: "k", model: "stt-rt-v5", options: dictation)
        XCTAssertEqual(codec.parse(.string(#"{"tokens":[{"text":"Hel","is_final":false}]}"#)), [.ready, .partial("Hel")])
        XCTAssertEqual(codec.parse(.string(#"{"tokens":[{"text":"Hello","is_final":true},{"text":" wor","is_final":false}]}"#)),
                       [.ready, .partial("Hello wor")])
        XCTAssertEqual(codec.parse(.string(#"{"tokens":[{"text":" world","is_final":true},{"text":"<end>","is_final":true}]}"#)),
                       [.ready, .final("Hello world"), .partial(""), .partial("")])
        XCTAssertEqual(codec.parse(.string(#"{"tokens":[{"text":"你好","is_final":true}]}"#)), [.ready, .partial("你好")])
        // 没有新 token 的进度响应不改动实时文本。
        XCTAssertEqual(codec.parse(.string(#"{"tokens":[],"final_audio_proc_ms":1200}"#)), [.ready])
        XCTAssertEqual(codec.parse(.string(#"{"tokens":[],"finished":true}"#)), [.ready, .final("你好"), .partial(""), .completed])
        XCTAssertEqual(codec.parse(.string(#"{"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key"}"#)),
                       [.failure("unauthenticated: Invalid API key")])
    }

    func testSonioxModelListKeepsRealtimeNonAliases() throws {
        let json = #"""
        {"models":[
          {"id":"stt-rt-v5","name":"Soniox v5 Real-time","transcription_mode":"real_time","aliased_model_id":null},
          {"id":"stt-rt-v4","name":"","transcription_mode":"real_time","aliased_model_id":"stt-rt-v5"},
          {"id":"stt-async-v5","name":"Async","transcription_mode":"async","aliased_model_id":null}
        ]}
        """#
        let models = try SonioxAPI.parseRealtimeModels(Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["stt-rt-v5"])
        XCTAssertEqual(models.first?.title, "Soniox v5 Real-time · stt-rt-v5")
        XCTAssertThrowsError(try SonioxAPI.parseRealtimeModels(Data("[]".utf8)))
    }

    // MARK: - 配置

    func testCloudConfigCompleteness() {
        var config = CloudConfig(apiKey: "", model: "m", region: .mainland, baseURL: "")
        XCTAssertFalse(config.isComplete(for: .volcengine))
        config.apiKey = "k"
        XCTAssertTrue(config.isComplete(for: .volcengine))
        XCTAssertFalse(config.isComplete(for: .openAICompatible), "OpenAI 兼容接口必须填地址")
        config.baseURL = "https://api.example.com/v1"
        XCTAssertTrue(config.isComplete(for: .openAICompatible))
        config.model = ""
        XCTAssertFalse(config.isComplete(for: .bailian))
    }

    func testCloudModelsAreInCatalog() {
        for provider in CloudProvider.allCases {
            let model = ModelCatalog.model(provider.modelID)
            XCTAssertNotNil(model)
            XCTAssertEqual(model?.cloudProvider, provider)
        }
        XCTAssertNil(ModelCatalog.all.first?.cloudProvider, "默认模型仍是本地模型")
    }

    func testCredentialStoreWritesPrivateFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ib-cred-\(UUID().uuidString)/credentials.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = CredentialStore(url: url)
        XCTAssertNil(store.value(for: "a"))
        store.set("secret", for: "a")
        store.set("other", for: "b")
        XCTAssertEqual(CredentialStore(url: url).value(for: "a"), "secret", "重新打开仍能读到")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600, "只有当前用户可读写")
        store.set(nil, for: "a")
        XCTAssertNil(store.value(for: "a"))
        XCTAssertEqual(store.value(for: "b"), "other")
    }
}

/// 链:LLMConfigForm → LLMModelCatalog.refresh → OpenAICompatibleAPI.listModels;CloudConfigSheet → OpenAICompatibleAPI(地址拼接、模型列表解析)→ CloudASREngine.transcriptionModels。
nonisolated final class ModelListTests: XCTestCase {
    func testEndpointTrimsSlashesAndRejectsBadURL() {
        XCTAssertEqual(OpenAICompatibleAPI.endpoint(" https://api.openai.com/v1// ", "models")?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertNil(OpenAICompatibleAPI.endpoint("", "models"))
        XCTAssertNil(OpenAICompatibleAPI.endpoint("api.openai.com", "models"), "没有 http(s) 协议头的地址无效")
    }

    func testParseModelListFormats() throws {
        XCTAssertEqual(try OpenAICompatibleAPI.parseModelList(Data(#"{"object":"list","data":[{"id":"b"},{"id":"a"},{"id":"a"}]}"#.utf8)), ["a", "b"])
        XCTAssertEqual(try OpenAICompatibleAPI.parseModelList(Data(#"{"models":[{"name":"qwen3:8b"}]}"#.utf8)), ["qwen3:8b"])
        XCTAssertEqual(try OpenAICompatibleAPI.parseModelList(Data(#"["m1"]"#.utf8)), ["m1"])
        XCTAssertThrowsError(try OpenAICompatibleAPI.parseModelList(Data("<html>".utf8)))
    }

    func testErrorMessage() {
        XCTAssertEqual(OpenAICompatibleAPI.errorMessage(Data(#"{"error":{"message":"bad key"}}"#.utf8), status: 401), "HTTP 401 bad key")
    }

    func testTranscriptionModelFilter() {
        let all = ["gpt-4o", "gpt-4o-mini-transcribe", "whisper-1", "tts-1", "gpt-4o-mini-tts"]
        XCTAssertEqual(CloudASREngine.transcriptionModels(all), ["gpt-4o-mini-transcribe", "whisper-1"])
        XCTAssertEqual(CloudASREngine.transcriptionModels(["foo", "bar"]), ["foo", "bar"], "匹配不上时返回全部")
    }

    func testEveryProviderHasModelsIncludingDefault() {
        for provider in CloudProvider.allCases {
            XCTAssertTrue(provider.knownModels.contains { $0.id == provider.defaultModel }, "\(provider) 的默认模型应在列表里")
        }
    }
}

/// 链:SubtitleController.handle(.final) → CaptionTranscript.append / setTranslation → TranscriptView / TranscriptSaver。
nonisolated final class CaptionTranscriptTests: XCTestCase {
    func testAppendTranslateAndExport() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var transcript = CaptionTranscript(appName: "Chrome", startedAt: start)
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertFalse(transcript.hasUnsavedEntries)
        let first = CaptionTranscript.Entry(time: start.addingTimeInterval(5), text: "Hello")
        transcript.append(first)
        transcript.append(.init(time: start.addingTimeInterval(3_725), text: "World"))
        transcript.setTranslation("你好", for: first.id, target: .zhHans)
        XCTAssertEqual(transcript.offset(of: transcript.entries[1]), "01:02:05")
        let text = transcript.plainText()
        XCTAssertTrue(text.hasPrefix("Chrome\n"))
        XCTAssertTrue(text.contains("[00:00:05] Hello\n           你好\n"))
        XCTAssertTrue(text.contains("[01:02:05] World"))
        XCTAssertFalse(transcript.plainText(includeTranslation: false).contains("你好"))
    }

    func testSavedStateTracksNewEntries() {
        var transcript = CaptionTranscript(appName: "A")
        transcript.append(.init(text: "1"))
        XCTAssertTrue(transcript.hasUnsavedEntries)
        transcript.markSaved()
        XCTAssertFalse(transcript.hasUnsavedEntries, "保存后没有新内容就不再询问")
        transcript.append(.init(text: "2"))
        XCTAssertTrue(transcript.hasUnsavedEntries)
    }

    /// 保存面板打开期间新到的句子不能算作已保存(否则结束时不会再询问,内容丢失)。
    func testMarkSavedUpToSnapshot() {
        var transcript = CaptionTranscript(appName: "A")
        transcript.append(.init(text: "1"))
        let snapshot = transcript
        transcript.append(.init(text: "2"))
        transcript.markSaved(upTo: snapshot.entries.count)
        XCTAssertTrue(transcript.hasUnsavedEntries)
        transcript.markSaved(upTo: 99)
        XCTAssertFalse(transcript.hasUnsavedEntries)
    }

    func testSuggestedFileNameIsSafe() {
        let transcript = CaptionTranscript(appName: "A/B:C", startedAt: Date())
        XCTAssertFalse(transcript.suggestedFileName.contains("/"))
        XCTAssertFalse(transcript.suggestedFileName.contains(":"))
        XCTAssertTrue(transcript.suggestedFileName.hasSuffix(".txt"))
    }
}

/// 链:SubtitleController.translate → TranslationService.translateLine → TextProcessor.translateSubtitle → LLMClient.stream(SSE 解析);
/// Prompts.target → TargetLanguage.autoPair。
nonisolated final class TranslationDisplayTests: XCTestCase {
    func testStreamLineParsing() {
        XCTAssertEqual(LLMClient.parseStreamLine(#"data: {"choices":[{"delta":{"content":"你好"}}]}"#), "你好")
        XCTAssertEqual(LLMClient.parseStreamLine("data: [DONE]"), LLMClient.streamDone)
        XCTAssertNil(LLMClient.parseStreamLine(": keep-alive"))
        XCTAssertNil(LLMClient.parseStreamLine(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
    }

    func testThinkingIsHiddenWhileStreaming() {
        XCTAssertNil(LLMClient.visibleText("<think>let me see"), "思考段结束前不显示")
        XCTAssertEqual(LLMClient.visibleText("<think>x</think>\n你好"), "你好")
        XCTAssertEqual(LLMClient.visibleText(" Hello "), "Hello")
    }

    func testClearTranslationForRetranslate() {
        var transcript = CaptionTranscript(appName: "A")
        let entry = CaptionTranscript.Entry(text: "Hi")
        transcript.append(entry)
        transcript.setTranslationFailed(for: entry.id)
        transcript.clearTranslation(for: entry.id)
        XCTAssertFalse(transcript.entries[0].translationSettled, "换语言重新翻译前清空状态")
    }

    func testLocaleMappingAndAutoPair() {
        XCTAssertEqual(TargetLanguage(localeIdentifier: "zh-Hans-CN"), .zhHans)
        XCTAssertEqual(TargetLanguage(localeIdentifier: "zh-TW"), .zhHant)
        XCTAssertEqual(TargetLanguage(localeIdentifier: "en-US"), .en)
        XCTAssertNil(TargetLanguage(localeIdentifier: "th-TH"))

        let chinese = TargetLanguage.autoPair(preferred: ["zh-Hans-CN", "en-US"])
        XCTAssertEqual(chinese.primary, .zhHans)
        XCTAssertEqual(chinese.other, .en)
        let english = TargetLanguage.autoPair(preferred: ["en-US", "ja-JP"])
        XCTAssertEqual(english.primary, .en)
        XCTAssertEqual(english.other, .ja, "主语言是英语时用第二首选语言")
        XCTAssertEqual(TargetLanguage.autoPair(preferred: ["en-US"]).other, .zhHans)
    }

    func testSubtitlePromptIncludesContextTranslations() {
        let user = Prompts.subtitleUser(current: "Is we're going to grow San Jose.",
                                        context: [(source: "The only way to hold more people at GTC.", translation: "容纳更多人的唯一办法")])
        XCTAssertTrue(user.contains("→ 容纳更多人的唯一办法"))
        XCTAssertTrue(user.hasSuffix("CURRENT: Is we're going to grow San Jose."))
        XCTAssertTrue(Prompts.target(.en).contains("English"))
    }
}

/// 链:TranslationService → LanguageDetector(识别源语言)→ TargetLanguage.resolved(确定目标)→ SystemTranslator。
nonisolated final class SystemTranslationTests: XCTestCase {
    private let zhUser = ["zh-Hans-CN", "en-US"]

    func testDetectAndCompareLanguages() {
        XCTAssertEqual(LanguageDetector.detect("The reason why human in the loop is challenging.")?.languageCode?.identifier, "en")
        XCTAssertEqual(LanguageDetector.detect("今天下午三点在会议室开会")?.languageCode?.identifier, "zh")
        XCTAssertTrue(LanguageDetector.same(Locale.Language(identifier: "zh"), Locale.Language(identifier: "zh-Hans")))
        XCTAssertFalse(LanguageDetector.same(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant")))
        XCTAssertTrue(LanguageDetector.same(Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en")))
    }

    func testResolvedTargetFollowsAutoRule() {
        let en = Locale.Language(identifier: "en"), zh = Locale.Language(identifier: "zh-Hans")
        XCTAssertEqual(TargetLanguage.auto.resolved(source: en, preferred: zhUser).minimalIdentifier, "zh", "英文 → 主语言中文")
        XCTAssertEqual(TargetLanguage.auto.resolved(source: zh, preferred: zhUser).minimalIdentifier, "en", "中文 → 另一种语言英文")
        XCTAssertEqual(TargetLanguage.ja.resolved(source: en, preferred: zhUser).minimalIdentifier, "ja", "固定目标直接用")
    }

    func testProbePairForDownload() {
        let auto = TranslationService.probePair(for: .auto, preferred: zhUser)
        XCTAssertEqual(auto.source.minimalIdentifier, "en")
        XCTAssertEqual(auto.target.minimalIdentifier, "zh")
        let toEnglish = TranslationService.probePair(for: .en, preferred: zhUser)
        XCTAssertEqual(toEnglish.source.minimalIdentifier, "zh")
    }

    func testSubtitlePromptHasNoMachineDraft() {
        XCTAssertEqual(Prompts.subtitleUser(current: "Hello", context: []), "CURRENT: Hello", "去掉混合模式后不再附带机翻初稿")
    }
}

/// 链:SubtitleController.handle → CaptionFeed → CaptionSegmenter(LocalAgreement 确认)→ SentenceSplitter → CaptionScheduler。
nonisolated final class CaptionPipelineTests: XCTestCase {
    func testSplitterBasics() {
        XCTAssertEqual(SentenceSplitter.split("Pi is about 3.14 in every textbook today. Next one", final: false).complete,
                       ["Pi is about 3.14 in every textbook today."], "小数点不断句")
        XCTAssertEqual(SentenceSplitter.split("你好世界今天天气很好。明天见", final: false).complete, ["你好世界今天天气很好。"])
        XCTAssertEqual(SentenceSplitter.split("Well, that's been reflected. In computing across the board. And", final: false).complete,
                       ["Well, that's been reflected. In computing across the board."], "碎片短句并入下一句")
        XCTAssertEqual(SentenceSplitter.split("We know.", final: true).complete, ["We know."], "定稿只有一句短句时保留")
        XCTAssertEqual(SentenceSplitter.split("We solved the quadratic equation in class today. We know.", final: true).complete,
                       ["We solved the quadratic equation in class today. We know."], "定稿末尾的短句并入前一句")
    }

    func testSplitterIsPrefixStable() {
        let text = "The rules of a right triangle, we know many, many rules of math and geometry and logic and science. We have puzzle games. Constraint"
        var previous: [String] = []
        for end in stride(from: 10, through: text.count, by: 7) {
            let complete = SentenceSplitter.split(String(text.prefix(end)), final: false).complete
            XCTAssertEqual(Array(complete.prefix(previous.count)), previous, "文字增长时已切出的句子不能变")
            previous = complete
        }
    }

    func testLocalAgreementConfirmsOnlyStableText() {
        var segmenter = CaptionSegmenter()
        XCTAssertEqual(segmenter.hypothesis("So AI infrastructure. For GM").sentences, [], "第一次结果还没确认")
        // 第二次结果修正了断句:之前的 "So AI infrastructure." 只确认到 "infrastructure",还不成句。
        XCTAssertEqual(segmenter.hypothesis("So AI infrastructure for GM partnering with GM.").sentences, [])
        let third = segmenter.hypothesis("So AI infrastructure for GM partnering with GM. And then also")
        XCTAssertEqual(third.sentences, ["So AI infrastructure for GM partnering with GM."], "确认后整句给出,没有被错误的早期断句截断")
        XCTAssertEqual(third.live, "And then also")
        XCTAssertEqual(segmenter.hypothesis("So AI infrastructure for GM partnering with GM. And then also AI").sentences, [], "已给出的句子不会再给一次")
    }

    func testConfirmedTextIsAppendOnly() {
        var segmenter = CaptionSegmenter()
        _ = segmenter.hypothesis("It understands things like friction and inertia. Cause")
        let shown = segmenter.hypothesis("It understands things like friction and inertia. Cause and")
        XCTAssertEqual(shown.sentences, ["It understands things like friction and inertia."])
        // 引擎后来把句号改成了逗号:已给出的句子不再重复给出,后面的内容接着成句。
        _ = segmenter.hypothesis("It understands things like friction and inertia, cause and effect and object permanence. When")
        let next = segmenter.hypothesis("It understands things like friction and inertia, cause and effect and object permanence. When someone")
        XCTAssertEqual(next.sentences, ["Cause and effect and object permanence."], "不重复已显示的部分")
    }

    func testFinalAddsOnlyWhatWasNotShown() {
        var segmenter = CaptionSegmenter()
        _ = segmenter.hypothesis("One of the areas I love. That I'm deeply proud of")
        _ = segmenter.hypothesis("One of the areas I love. That I'm deeply proud of and")
        XCTAssertEqual(segmenter.emittedTokens, 6)
        let rest = segmenter.final("One of the areas I love. That I'm deeply proud of, and it rarely gets any attention.")
        XCTAssertEqual(rest, ["That I'm deeply proud of, and it rarely gets any attention."], "定稿只补上没显示的部分")
    }

    func testFinalAlignsWhenWordingDiffers() {
        var segmenter = CaptionSegmenter()
        _ = segmenter.hypothesis("Well we know the equation of it. How to")
        _ = segmenter.hypothesis("Well we know the equation of it. How to solve")
        // 定稿去掉了开头的 "Well":按最后几个词定位,不会重复也不会漏。
        XCTAssertEqual(segmenter.final("We know the equation of it. How to solve that."), ["How to solve that."])
    }

    func testMultiSegmentFinalCarriesShownWords() {
        var segmenter = CaptionSegmenter()
        _ = segmenter.hypothesis("First segment is here. Second segment goes on. More")
        _ = segmenter.hypothesis("First segment is here. Second segment goes on. More words")
        // 引擎分两次定稿:第一段只含第一句,第二句已经显示过,留给下一次抵扣。
        XCTAssertEqual(segmenter.final("First segment is here."), [])
        XCTAssertEqual(segmenter.final("Second segment goes on. More words follow now."), ["More words follow now."])
    }

    private func unit(_ text: String, _ translation: String? = nil, age: TimeInterval = 0, now: Date) -> CaptionUnit {
        var unit = CaptionUnit(source: text, createdAt: now.addingTimeInterval(-age))
        unit.translation = translation
        return unit
    }

    func testRollingSourceFollowsSpeechAndTranslationFollowsSentences() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [unit("First sentence is complete here.", "第一句已经完整。", now: now),
                     unit("Second sentence waits for translation.", nil, now: now)]
        captions.update(&units, live: "and the speaker keeps", translating: true, timeout: 4, now: now)
        XCTAssertEqual(captions.sourceFinal, "First sentence is complete here. Second sentence waits for translation.")
        XCTAssertEqual(captions.sourceLive, " and the speaker keeps", "原文行实时接上正在说的部分")
        XCTAssertEqual(captions.translation, "第一句已经完整。", "译文行只接到第一句,第二句还在等")

        units[1].translation = "第二句等待翻译。"
        captions.update(&units, live: "", translating: true, timeout: 4, now: now)
        XCTAssertEqual(captions.translation, "第一句已经完整。第二句等待翻译。")

        // 已接上的译文锁定:之后 AI 润色版到达也不改字幕条。
        units[0].translation = "第一句（润色版）。"
        captions.update(&units, live: "", translating: true, timeout: 4, now: now)
        XCTAssertEqual(captions.translation, "第一句已经完整。第二句等待翻译。")
    }

    func testRollingNeverDropsSentenceWhoseTranslationTimesOut() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [unit("Stuck sentence without translation.", nil, age: 5, now: now),
                     unit("Next sentence translated fine.", "下一句。", now: now)]
        captions.update(&units, live: "", translating: true, timeout: 4, now: now)
        XCTAssertEqual(captions.translationFinal, "", "顶替的内容按暂定样式显示")
        XCTAssertTrue(captions.translationLive.contains("Stuck sentence without translation."), "等不到译文时用原文顶替,不丢句")
        XCTAssertTrue(captions.translationLive.hasSuffix("下一句。"), "后面的句子照常接上")
        XCTAssertFalse(captions.translationWaiting)
    }

    func testRollingTrimsWholeSentencesOccasionally() {
        let now = Date()
        var captions = RollingCaptions()
        var units = (0..<20).map { unit("This is sentence number \($0) of the talk.", nil, now: now) }
        captions.update(&units, live: "", translating: false, timeout: 4, now: now)
        XCTAssertLessThanOrEqual(captions.sourceFinal.count, RollingCaptions.trimAt)
        XCTAssertTrue(captions.sourceFinal.hasPrefix("This is sentence"), "按整句裁剪,开头是完整的句子")
        XCTAssertTrue(captions.sourceFinal.hasSuffix("number 19 of the talk."))
        let before = captions.sourceFinal
        units.append(unit("One more.", nil, now: now))
        captions.update(&units, live: "", translating: false, timeout: 4, now: now)
        XCTAssertTrue(captions.sourceFinal.hasPrefix(before), "没超过上限时起点不动,只在末尾增长(换行稳定)")
    }
}

/// 链:SummaryView → TranscriptSummarizer.summarize → AppSettings.summaryLLMConfig → Prompts.summarize / summaryUser → LLMClient.stream。
nonisolated final class SummaryTests: XCTestCase {
    @MainActor
    func testSummaryUsesServiceFromSettings() {
        let defaults = UserDefaults(suiteName: "ib-summary-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.llmBaseURL = ""
        XCTAssertNil(settings.summaryLLMConfig, "设置里没有服务时不能总结")
        settings.llmBaseURL = "https://main.example.com/v1"
        settings.llmModel = "main-model"
        XCTAssertEqual(settings.summaryLLMConfig?.model, "main-model", "默认跟随 AI 设置的模型")
        settings.summaryModel = "bigger-model"
        XCTAssertEqual(settings.summaryLLMConfig?.model, "bigger-model", "可以另选同一接口的模型")
        XCTAssertEqual(settings.summaryLLMConfig?.baseURL, "https://main.example.com/v1", "接口始终来自设置")
    }

    func testSummaryPromptIncludesPreviousForContinuity() {
        XCTAssertEqual(Prompts.summaryUser(transcript: "a\nb", previous: nil), "NEW TRANSCRIPT:\na\nb")
        XCTAssertTrue(Prompts.summaryUser(transcript: "c", previous: "- x").hasPrefix("PREVIOUS SUMMARY:\n- x\n\nNEW TRANSCRIPT:"))
        XCTAssertTrue(Prompts.summarize(language: .zhHans).contains("Simplified Chinese"))
    }
}

/// 链:字幕记录窗口「总结」页 SummaryView「总结全文」→ TranscriptSummarizer.summarizeAll → runAll(chunks → Prompts.summaryNotes → Prompts.summarizeAll);
/// 保存:TranscriptSaver.save → CaptionTranscript.plainText(summary:)(总结写在字幕前面)。
nonisolated final class FullSummaryTests: XCTestCase {
    func testChunksKeepLinesWhole() {
        let text = (0..<10).map { "Line number \($0) with some words." }.joined(separator: "\n")
        let chunks = TranscriptSummarizer.chunks(text, size: 80)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 80 })
        XCTAssertEqual(chunks.joined(separator: "\n"), text, "分块不丢内容、不切断句子")
        XCTAssertEqual(TranscriptSummarizer.chunks("short", size: 80), ["short"])
    }

    func testExportIncludesSummaryBeforeTranscript() {
        var transcript = CaptionTranscript(appName: "Chrome", startedAt: Date())
        transcript.append(.init(text: "Hello world."))
        let text = transcript.plainText(summary: "全文总结\n- 要点")
        let summaryIndex = text.range(of: "- 要点")!.lowerBound
        let lineIndex = text.range(of: "Hello world.")!.lowerBound
        XCTAssertLessThan(summaryIndex, lineIndex, "总结写在字幕前面")
        XCTAssertFalse(transcript.plainText().contains("【"), "没有总结时不加总结标题")
    }
}
