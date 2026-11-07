import AppKit

/// 开始 / 结束 / 失败的提示音(系统内置音效,音量较低)。
@MainActor
final class SoundEffects {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() { play("Pop", volume: 0.35) }
    func stop() { play("Tink", volume: 0.3) }
    func error() { play("Basso", volume: 0.3) }

    private func play(_ name: String, volume: Float) {
        guard settings.soundEffects, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
