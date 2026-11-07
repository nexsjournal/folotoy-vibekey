import Foundation

/// 把触发键的"按下 / 松开"翻译成开始或结束录音。
/// 快捷键保留短按免提;Passport 使用按住说话,过短的按压视为误触并取消。
nonisolated struct PressInterpreter: Sendable {
    enum Action: Equatable { case start, stop, cancel, none }
    enum Style: Sendable { case hybrid, pushToTalk }

    var holdThreshold: TimeInterval = 0.3
    var minimumDeviceHold: TimeInterval = 0.25
    private(set) var isActive = false
    /// 短按后进入免提模式,松开不结束。
    private(set) var isHandsFree = false
    // 使用单调运行时间,避免系统校时影响误触阈值。
    private var pressedAt: TimeInterval?
    private var style: Style = .hybrid

    mutating func down(at time: TimeInterval = ProcessInfo.processInfo.systemUptime, style: Style = .hybrid) -> Action {
        if isActive {
            // 免提模式下再按一次:结束。
            reset()
            return .stop
        }
        isActive = true
        isHandsFree = false
        pressedAt = time
        self.style = style
        return .start
    }

    mutating func up(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Action {
        guard isActive, let pressedAt else { return .none }
        self.pressedAt = nil
        if style == .pushToTalk {
            let valid = time - pressedAt >= minimumDeviceHold
            reset()
            return valid ? .stop : .cancel
        }
        if time - pressedAt >= holdThreshold {
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
        style = .hybrid
    }
}
