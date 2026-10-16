import AVFoundation
import CoreAudio

/// 系统麦克风(任意输入设备),AVAudioEngine 采集后转成 16 kHz 单声道。
nonisolated final class MicSource: AudioSource, @unchecked Sendable {
    var onSamples: (@Sendable ([Float]) -> Void)?
    private let deviceUID: String?
    private var engine: AVAudioEngine?
    private let converter = AudioConverter()
    private let queue = DispatchQueue(label: "InputBetter.mic", qos: .userInteractive)

    /// `deviceUID` 为 nil 时使用系统默认输入设备。
    init(deviceUID: String?) {
        self.deviceUID = deviceUID
    }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID, let id = CoreAudioQuery.deviceID(forUID: deviceUID) {
            do {
                try input.auAudioUnit.setDeviceID(id)
            } catch {
                Log.audio.error("set input device failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "InputBetter", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "麦克风不可用", bundle: .l10n)])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // 转换放到串行队列,避免阻塞音频线程。
            nonisolated(unsafe) let buffer = buffer
            self.queue.async {
                let samples = self.converter.convert(buffer)
                if !samples.isEmpty { self.onSamples?(samples) }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        Log.audio.info("mic started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
