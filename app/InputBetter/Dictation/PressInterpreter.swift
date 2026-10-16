import Foundation

/// 把触发键的"按下 / 松开"翻译成开始或结束录音。
/// 规则(快捷键与 Passport OK 键共用):
/// - 按住超过 `holdThreshold` 再松开:按住说话,松开即结束;
/// - 短按:开始录音并保持,再按一次结束(免提模式)。
nonisolated struct PressInterpreter: Sendable {
    enum Action: Equatable { case start, stop, none }

    var holdThreshold: TimeInterval = 0.3
    private(set) var isActive = false
    /// 短按后进入免提模式,松开不结束。
    private(set) var isHandsFree = false
    private var pressedAt: Date?

    mutating func down(at time: Date = Date()) -> Action {
        if isActive {
            // 免提模式下再按一次:结束。
            reset()
            return .stop
        }
        isActive = true
        isHandsFree = false
        pressedAt = time
        return .start
    }

    mutating func up(at time: Date = Date()) -> Action {
        guard isActive, let pressedAt else { return .none }
        self.pressedAt = nil
        if time.timeIntervalSince(pressedAt) >= holdThreshold {
            reset()
            return .stop
        }
        isHandsFree = true
        return .none
    }

    /// 录音因其他原因结束(点击 ✓ / ✕、出错)时调用,保持状态一致。
    mutating func reset() {
        isActive = false
        isHandsFree = false
        pressedAt = nil
    }
}
