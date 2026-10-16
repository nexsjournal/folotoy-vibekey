import Foundation
import SherpaOnnx

/// SenseVoice Small(sherpa-onnx,int8),配合 VAD 分段。
@MainActor
final class SenseVoiceEngine: ASREngine {
    private var decoder: SenseVoiceDecoder?
    private var language: SpeechLanguage?

    var isLoaded: Bool { decoder != nil }

    func prepare() async throws {
        try await load(language: language ?? .auto)
    }

    func makeSession(_ options: ASROptions) async throws -> ASRSession {
        // 语言写在识别器配置里,语言变化时重新加载。
        if decoder == nil || language != options.language {
            try await load(language: options.language)
        }
        guard let decoder else { throw ASRError.notLoaded }
        return SegmentedSession(decoder: decoder, options: options)
    }

    func unload() {
        decoder = nil
    }

    private func load(language: SpeechLanguage) async throws {
        let dir = ModelManager.senseVoiceDir
        let model = dir.appendingPathComponent("model.int8.onnx").path
        let tokens = dir.appendingPathComponent("tokens.txt").path
        guard FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: tokens) else {
            throw ASRError.modelMissing
        }
        let started = Date()
        decoder = try await SenseVoiceDecoder.load(model: model, tokens: tokens, language: language.isoCode ?? "auto")
        self.language = language
        Log.asr.info("SenseVoice loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
    }
}

nonisolated final class SenseVoiceDecoder: SegmentDecoder, @unchecked Sendable {
    /// 识别中结果的刷新间隔:SenseVoice 识别 8 秒音频只要 0.1–0.2 秒,0.4 秒刷新一次让字幕原文紧跟语音。
    let partialInterval = 0.4
    let maxWholeSeconds = 30.0
    let prefersWholeDictation = false
    private let recognizer: SherpaOnnxOfflineRecognizer
    private let queue = DispatchQueue(label: "InputBetter.sensevoice", qos: .userInitiated)

    private init(recognizer: SherpaOnnxOfflineRecognizer) {
        self.recognizer = recognizer
    }

    static func load(model: String, tokens: String, language: String) async throws -> SenseVoiceDecoder {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    let threads = max(2, min(ProcessInfo.processInfo.activeProcessorCount / 2, 6))
                    let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
                        model: model, language: language, useInverseTextNormalization: true)
                    let modelConfig = sherpaOnnxOfflineModelConfig(
                        tokens: tokens, numThreads: threads, provider: "cpu", debug: 0, senseVoice: senseVoice)
                    var config = sherpaOnnxOfflineRecognizerConfig(
                        featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80),
                        modelConfig: modelConfig)
                    let recognizer = SherpaOnnxOfflineRecognizer(config: &config)
                    cont.resume(returning: SenseVoiceDecoder(recognizer: recognizer))
                }
            }
        }
    }

    func decode(_ samples: [Float], options: ASROptions) async throws -> String {
        guard samples.count >= 1_600 else { return "" }
        return await withCheckedContinuation { cont in
            queue.async {
                let text = self.recognizer.decode(samples: samples, sampleRate: 16_000).text
                cont.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

nonisolated enum ASRError: LocalizedError {
    case notLoaded, modelMissing, unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: String(localized: "模型未加载", bundle: .l10n)
        case .modelMissing: String(localized: "模型尚未下载", bundle: .l10n)
        case .unsupportedLanguage(let l): String(localized: "该引擎不支持\(l)", bundle: .l10n)
        }
    }
}
