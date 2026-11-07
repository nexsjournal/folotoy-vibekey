import Foundation
import os
import WhisperKit

/// WhisperKit(CoreML / 神经网络引擎)。首次加载时 CoreML 需要为本机芯片优化模型,可能耗时一两分钟。
@MainActor
final class WhisperEngine: ASREngine {
    let modelID: String
    private var decoder: WhisperDecoder?
    private var loading: Task<WhisperDecoder, Error>?

    init(modelID: String) {
        self.modelID = modelID
    }

    var isLoaded: Bool { decoder != nil }

    func prepare() async throws {
        if decoder != nil { return }
        if let loading {
            decoder = try await loading.value
            return
        }
        guard let folder = ModelManager.whisperFolder(modelID) else { throw ASRError.modelMissing }
        let task = Task.detached(priority: .userInitiated) { () throws -> WhisperDecoder in
            let started = Date()
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false)
            let kit = try await WhisperKit(config)
            let decoder = WhisperDecoder(kit: kit)
            // 用一小段静音预热解码管线,第一次真正听写时不再卡顿。
            _ = try? await decoder.decode([Float](repeating: 0, count: 16_000), options: ASROptions(purpose: .dictation, language: .en, vocabulary: []))
            Log.asr.info("Whisper loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            return decoder
        }
        loading = task
        defer { loading = nil }
        decoder = try await task.value
    }

    func makeSession(_ options: ASROptions) async throws -> ASRSession {
        try await prepare()
        guard let decoder else { throw ASRError.notLoaded }
        return SegmentedSession(decoder: decoder, options: options)
    }

    func unload() {
        decoder = nil
    }
}

/// 串行化 WhisperKit 调用。
actor WhisperRunner {
    private let kit: WhisperKit
    init(kit: sending WhisperKit) { self.kit = kit }

    func transcribe(_ samples: [Float], options: DecodingOptions) async -> String {
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            return results.map(\.text).joined(separator: " ")
        } catch {
            Log.asr.error("whisper transcribe failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// 检测语言(只用前 30 秒),失败返回 nil。
    func detectLanguage(_ samples: [Float]) async -> String? {
        try? await kit.detectLangauge(audioArray: Array(samples.prefix(16_000 * 30))).language
    }

    func promptTokens(_ text: String) -> [Int]? {
        guard let tokenizer = kit.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : Array(tokens.suffix(200))
    }
}

nonisolated final class WhisperDecoder: SegmentDecoder, @unchecked Sendable {
    let partialInterval = 1.0
    let maxWholeSeconds = 600.0
    let prefersWholeDictation = true
    private let runner: WhisperRunner
    /// 最近一次检测到的语言。录音中的实时预览已经检测过,结束时的整段识别直接复用,省一次编码。
    private let detected = OSAllocatedUnfairLock<(language: String, at: Date)?>(initialState: nil)

    init(kit: sending WhisperKit) {
        runner = WhisperRunner(kit: kit)
    }

    func decode(_ samples: [Float], options: ASROptions) async throws -> String {
        guard samples.count >= 4_000 else { return "" }
        // 自动模式先检测语言:中文提示词只用于中文,否则会让英文解码反复回退、变慢。
        var language = options.language.isoCode ?? "en"
        if options.language == .auto {
            if let cached = detected.withLock({ $0 }), Date().timeIntervalSince(cached.at) < 3, samples.count > 16_000 * 2 {
                language = cached.language
            } else if let found = await runner.detectLanguage(samples) {
                language = found
                detected.withLock { $0 = (found, Date()) }
            }
        }
        let chinese = language == "zh" || language == "yue"
        // 提示词:中文引导输出简体与标点,同时带上词汇表。
        var prompt = chinese ? "以下是普通话的句子，使用简体中文和标点。" : ""
        if !options.vocabulary.isEmpty { prompt += " " + options.vocabulary.joined(separator: ", ") }
        let promptTokens = prompt.isEmpty ? nil : await runner.promptTokens(prompt)
        let decodeOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 2,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            noSpeechThreshold: 0.6,
            chunkingStrategy: samples.count > 16_000 * 30 ? .vad : nil)
        var text = await runner.transcribe(samples, options: decodeOptions)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if chinese || text.unicodeScalars.contains(where: TranscriptText.isCJK) {
            text = TranscriptText.toSimplified(text)
        }
        return text
    }
}
