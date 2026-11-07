import AVFoundation
import Speech

/// Apple SpeechAnalyzer + SpeechTranscriber(macOS 26),原生流式识别。
@MainActor
final class AppleSpeechEngine: ASREngine {
    private(set) var isLoaded = false

    func prepare() async throws {
        isLoaded = true
    }

    func makeSession(_ options: ASROptions) async throws -> ASRSession {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: options.language.appleLocale) else {
            throw ASRError.unsupportedLanguage(options.language.title)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: options.purpose == .subtitles ? [.volatileResults, .fastResults] : [.volatileResults],
            attributeOptions: [])
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let session = try await AppleSpeechSession(transcriber: transcriber, vocabulary: options.vocabulary)
        isLoaded = true
        return session
    }

    func unload() {}
}

nonisolated final class AppleSpeechSession: ASRSession, @unchecked Sendable {
    let events: AsyncStream<TranscriptEvent>
    private let sink: AsyncStream<TranscriptEvent>.Continuation
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    /// 16 kHz 识别输入 → 分析器要求的格式。
    private let converter: AudioConverter
    private let lock = NSLock()
    private var committed: [String] = []
    private var resultsTask: Task<Void, Never>?

    init(transcriber: SpeechTranscriber, vocabulary: [String]) async throws {
        (events, sink) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = cont
        analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? AudioFormats.asr
        converter = AudioConverter(target: format)
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        resultsTask = Task.detached { [sink, weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self?.appendCommitted(text)
                        sink.yield(.final(text))
                        sink.yield(.partial(""))
                    } else {
                        sink.yield(.partial(text))
                    }
                }
            } catch {
                Log.asr.error("apple speech results failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    private func appendCommitted(_ text: String) {
        lock.withLock { committed.append(text) }
    }

    func feed(_ samples: [Float]) {
        guard let buffer = AudioFormats.buffer(from: samples) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let converted = converter.convertBuffer(buffer) {
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() async -> String {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.asr.error("apple speech finalize failed: \(error.localizedDescription, privacy: .public)")
        }
        await resultsTask?.value
        sink.finish()
        return lock.withLock { TranscriptText.join(committed) }
    }

    func cancel() {
        input.finish()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
        resultsTask?.cancel()
        sink.finish()
    }
}
