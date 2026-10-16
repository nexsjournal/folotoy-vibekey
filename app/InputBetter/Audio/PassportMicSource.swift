import Foundation

/// Passport 设备上的麦克风:设备把 16 kHz IMA ADPCM 经 USB / 蓝牙推上来,DeviceLink 解码成 Float。
nonisolated final class PassportMicSource: AudioSource, @unchecked Sendable {
    var onSamples: (@Sendable ([Float]) -> Void)?
    private let link: DeviceLink

    init(link: DeviceLink) {
        self.link = link
    }

    func start() throws {
        try MainActor.assumeIsolated {
            guard link.connection != .disconnected else {
                throw NSError(domain: "InputBetter", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Passport 未连接", bundle: .l10n)])
            }
            link.onMicSamples = { [weak self] samples in self?.onSamples?(samples) }
            link.setMic(true)
        }
    }

    func stop() {
        MainActor.assumeIsolated {
            link.setMic(false)
            link.onMicSamples = nil
        }
    }
}
