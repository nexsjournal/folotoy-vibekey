import Foundation
import SherpaOnnx

/// 非流式模型(SenseVoice、Whisper)的解码接口。实现方保证同一时刻只解码一段。
nonisolated protocol SegmentDecoder: Sendable {
    /// 录音过程中刷新 partial 的最小间隔(秒)。
    var partialInterval: Double { get }
    /// 听写结束时整段重识别的最长时长,更长的录音按 VAD 分段结果拼接。
    var maxWholeSeconds: Double { get }
    /// 听写时不逐句解码,只定期整段解码做实时预览、结束时整段识别一次(Whisper 逐句解码太贵,且整段上下文更准)。
    var prefersWholeDictation: Bool { get }
    /// 解码一段音频;本地模型不会抛错,云端接口可能因网络 / 鉴权失败而抛错。
    func decode(_ samples: [Float], options: ASROptions) async throws -> String
}

/// silero-vad 的薄封装。非线程安全,只在 SegmentedSession 的处理任务里使用。
nonisolated final class VoiceActivityDetector: @unchecked Sendable {
    struct Segment { let start: Int; let samples: [Float] }

    static let windowSize = 512
    private let vad: SherpaOnnxVoiceActivityDetectorWrapper
    private var pending: [Float] = []

    init?(purpose: ASRPurpose) {
        guard let path = Bundle.main.path(forResource: "silero_vad", ofType: "onnx") else { return nil }
        var made: SherpaOnnxVoiceActivityDetectorWrapper?
        autoreleasepool {
            let silero = sherpaOnnxSileroVadModelConfig(
                model: path,
                threshold: 0.45,
                minSilenceDuration: purpose == .dictation ? 0.6 : 0.35,
                minSpeechDuration: 0.2,
                windowSize: Self.windowSize,
                maxSpeechDuration: purpose == .dictation ? 25 : 8)
            var config = sherpaOnnxVadModelConfig(sileroVad: silero, sampleRate: 16_000, numThreads: 1)
            made = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 120)
        }
        guard let made else { return nil }
        vad = made
    }

    func accept(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= Self.windowSize {
            vad.acceptWaveform(samples: Array(pending[offset..<offset + Self.windowSize]))
            offset += Self.windowSize
        }
        pending.removeFirst(offset)
    }

    var isSpeech: Bool { vad.isSpeechDetected() }

    func popSegments() -> [Segment] {
        var out: [Segment] = []
        while !vad.isEmpty() {
            let s = vad.front()
            out.append(Segment(start: s.start, samples: s.samples))
            vad.pop()
        }
        return out
    }

    func flush() -> [Segment] {
        if !pending.isEmpty {
            vad.acceptWaveform(samples: pending + [Float](repeating: 0, count: Self.windowSize - pending.count))
            pending = []
        }
        vad.flush()
        return popSegments()
    }
}

/// 用 VAD 把连续音频切成句子,逐句交给非流式模型解码,模拟流式效果。
/// 听写结束时(时长允许的话)整段再识别一次,准确率最好。
nonisolated final class SegmentedSession: ASRSession, @unchecked Sendable {
    let events: AsyncStream<TranscriptEvent>
    private let eventSink: AsyncStream<TranscriptEvent>.Continuation
    private let input: AsyncStream<[Float]>.Continuation
    private var pump: Task<String, Never>!
    private let decoder: SegmentDecoder
    private let options: ASROptions
    /// 暂停标志(听写期间为 true);处理任务在每次解码前检查。
    private let paused = PauseGate()

    init(decoder: SegmentDecoder, options: ASROptions) {
        self.decoder = decoder
        self.options = options
        (events, eventSink) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let (stream, cont) = AsyncStream.makeStream(of: [Float].self)
        input = cont
        let vad = VoiceActivityDetector(purpose: options.purpose)
        let gate = paused
        pump = Task.detached(priority: .userInitiated) { [decoder, options, eventSink] in
            await Self.run(stream: stream, vad: vad, decoder: decoder, options: options, sink: eventSink, gate: gate)
        }
    }

    func feed(_ samples: [Float]) { input.yield(samples) }

    func finish() async -> String {
        input.finish()
        let text = await pump.value
        eventSink.finish()
        return text
    }

    func setDecodingPaused(_ paused: Bool) {
        self.paused.set(paused)
    }

    func cancel() {
        input.finish()
        pump.cancel()
        eventSink.finish()
    }

    /// 解码失败时报告一次错误并返回空文本,不打断整条会话。
    private static func decodeSafely(_ decoder: SegmentDecoder, sink: AsyncStream<TranscriptEvent>.Continuation,
                                     _ samples: [Float], options: ASROptions) async -> String {
        do {
            return try await decoder.decode(samples, options: options)
        } catch {
            sink.yield(.failure(error.localizedDescription))
            return ""
        }
    }

    private static func run(stream: AsyncStream<[Float]>, vad: VoiceActivityDetector?, decoder: SegmentDecoder,
                            options: ASROptions, sink: AsyncStream<TranscriptEvent>.Continuation,
                            gate: PauseGate) async -> String {
        var audio: [Float] = []          // 从 base 开始的采样
        var base = 0                     // audio[0] 在整条音频中的位置
        var committedEnd = 0             // 已定稿到的位置（绝对坐标）
        var committed: [String] = []
        var speechRanges: [Range<Int>] = []
        var lastPartial = Date.distantPast
        // 最近一次实时预览的结果及其覆盖到的位置(绝对坐标)。
        var lastPartialText = ""
        var lastPartialEnd = 0
        let isDictation = options.purpose == .dictation
        let wholeOnly = isDictation && decoder.prefersWholeDictation

        func commit(_ segments: [VoiceActivityDetector.Segment]) async {
            for seg in segments {
                speechRanges.append(seg.start..<(seg.start + seg.samples.count))
                if wholeOnly { continue }
                committedEnd = seg.start + seg.samples.count
                let text = await Self.decodeSafely(decoder, sink: sink, seg.samples, options: options)
                guard !Task.isCancelled else { return }
                if !text.isEmpty, !TranscriptText.isHallucination(text) {
                    committed.append(text)
                    sink.yield(.final(text))
                }
                sink.yield(.partial(""))
            }
        }

        for await chunk in stream {
            if Task.isCancelled { return "" }
            // 听写优先:暂停期间先攒着音频,不占用识别算力。
            await gate.waitWhilePaused()
            audio.append(contentsOf: chunk)
            guard let vad else { continue }
            vad.accept(chunk)
            await commit(vad.popSegments())

            // 字幕模式下丢掉已定稿的音频,避免长时间运行内存增长。
            if !isDictation, committedEnd - base > 16_000 * 5 {
                let drop = committedEnd - base
                audio.removeFirst(drop)
                base += drop
            }

            // 说话过程中定期解码未定稿部分,显示实时 partial(整段模式下从第一句开始解码)。
            if vad.isSpeech || (wholeOnly && !speechRanges.isEmpty),
               Date().timeIntervalSince(lastPartial) >= decoder.partialInterval {
                let from = wholeOnly ? max((speechRanges.first?.lowerBound ?? 0) - 3_200 - base, 0) : max(committedEnd - base, 0)
                if audio.count - from > 8_000 {
                    let coveredEnd = base + audio.count
                    let text = await Self.decodeSafely(decoder, sink: sink, Array(audio[from...]), options: options)
                    if !TranscriptText.isHallucination(text) {
                        sink.yield(.partial(text))
                        if wholeOnly { lastPartialText = text; lastPartialEnd = coveredEnd }
                    }
                    // 解码结束后才开始计时:解码期间积压的音频先被快速消化,处理队列不会越积越多。
                    lastPartial = Date()
                }
            }
        }
        guard !Task.isCancelled else { return "" }

        if let vad { await commit(vad.flush()) } else {
            // 没有 VAD 模型时退化为整段识别。
            speechRanges = [0..<audio.count]
        }
        guard !speechRanges.isEmpty else { return "" }

        // 整段模式:说完停顿后实时预览已经识别过全部语音,直接用它,松开后几乎零等待。
        if wholeOnly, !lastPartialText.isEmpty, let last = speechRanges.last, last.upperBound <= lastPartialEnd {
            return lastPartialText
        }

        // 听写:整段重识别(去掉首尾静音),上下文完整,准确率更高。
        if isDictation {
            let pad = 3_200
            let start = max(speechRanges.first!.lowerBound - pad - base, 0)
            let end = min(speechRanges.last!.upperBound + pad - base, audio.count)
            if end > start, Double(end - start) / 16_000 <= decoder.maxWholeSeconds {
                let text = await Self.decodeSafely(decoder, sink: sink, Array(audio[start..<end]), options: options)
                if !text.isEmpty, !TranscriptText.isHallucination(text) { return text }
            }
        }
        return TranscriptText.join(committed)
    }
}

/// 线程安全的暂停开关。等待方以 50 ms 间隔检查(暂停通常只持续一次听写的几秒)。
nonisolated final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    func set(_ value: Bool) { lock.withLock { paused = value } }
    var isPaused: Bool { lock.withLock { paused } }

    func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
