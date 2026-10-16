import AVFoundation

/// 所有音源统一输出 16 kHz 单声道 Float32 采样。`onSamples` 在音频线程上调用。
nonisolated protocol AudioSource: AnyObject {
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    func start() throws
    func stop()
}

nonisolated enum AudioFormats {
    static let sampleRate: Double = 16_000
    static let asr = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// 0...1 的响度,用于波形动画(RMS 转 dB 再归一化)。
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(samples.count))
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 55) / 45, 0), 1)
    }

    /// 电平平滑:上升立即跟随,下降按 `decay` 缓慢回落(波形和音量条更有弹性)。全 app 共用。
    static func smoothLevel(_ current: Float, toward new: Float, decay: Float = 0.8) -> Float {
        new > current ? new : current * decay + new * (1 - decay)
    }
}

/// PCM 格式转换(采样率 / 声道 / 采样格式)。全 app 唯一的转换实现:
/// 音源转成 16 kHz 单声道送识别,Apple Speech 再转成分析器要求的格式,都用它。
/// 非线程安全,调用方保证串行。
nonisolated final class AudioConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(target: AVAudioFormat = AudioFormats.asr) {
        self.target = target
    }

    /// 转成目标格式的缓冲;输入已经是目标格式时原样返回。
    func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        if format == target { return buffer }
        if inputFormat != format {
            converter = AVAudioConverter(from: format, to: target)
            // 多声道混成单声道,而不是只取第一声道。
            if format.channelCount > target.channelCount { converter?.downmix = true }
            // 不做首尾预填充:流式转换时每块输出立即对齐输入,不会在开头丢掉约 70 ms。
            converter?.primeMethod = .none
            inputFormat = format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// 转成目标格式后取第一声道的 Float 采样(目标为 16 kHz 单声道时即识别输入)。
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let out = convertBuffer(buffer), let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

nonisolated extension AudioFormats {
    /// Float 采样 → 16 bit 小端 PCM(云端识别的通用输入格式)。超出 ±1 的部分截断。
    static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                out[i] = Int16(littleEndian: Int16(max(-1, min(1, s)) * Float(Int16.max)))
            }
        }
        return data
    }

    /// 16 kHz 单声道 16 bit WAV 文件(上传到转写接口用)。
    static func wav(_ samples: [Float]) -> Data {
        let pcm = pcm16(samples)
        var header = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate) * 2); append16(2); append16(16)
        header.append(contentsOf: Array("data".utf8)); append32(UInt32(pcm.count))
        return header + pcm
    }

    /// 把 16 kHz 单声道 Float 采样包装成 PCM 缓冲。
    static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: asr, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
