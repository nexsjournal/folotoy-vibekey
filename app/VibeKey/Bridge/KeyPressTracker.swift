import Foundation

/// 把设备上报的原始按键事件(down / long / up)整理成可靠的手势,遵循通行的按键手势规则:
/// 1. **一次按压只属于一个处理者**:从按下那刻决定归属(普通 / 切换应用列表 / 关闭通知),
///    之后这次按压的 long、up 都交给同一处理者,即使中途模式变了(例如列表已关闭)。
/// 2. **短按在松开时判定**:同一个键同时有短按和长按动作时,只有松开前没触发长按才算短按,
///    避免"长按时先触发了短按动作"。
/// 3. **防抖锁定**:模态界面刚关闭后的极短时间内,同一个键的新按下视为抖动,整次按压忽略。
/// 纯值类型,不依赖设备与界面,便于沿调用链单独测试。
nonisolated struct KeyPressTracker: Sendable {
    enum Owner: Equatable, Sendable {
        case normal
        case switcher
        /// 这次按压用于关闭 Agent 通知,不触发任何动作。
        case agentAck
        /// 被防抖锁定忽略的按压。
        case ignored
    }

    private struct Press: Sendable {
        let owner: Owner
        var longFired = false
    }

    private var presses: [DeviceKey: Press] = [:]
    private var lockouts: [DeviceKey: Date] = [:]

    /// 按下:登记归属;处于防抖锁定期内则记为 ignored 并返回 nil。
    mutating func began(_ key: DeviceKey, owner: Owner, at time: Date = Date()) -> Owner? {
        if let until = lockouts[key], time < until {
            presses[key] = Press(owner: .ignored)
            return nil
        }
        presses[key] = Press(owner: owner)
        return owner
    }

    /// 长按:返回这次按压的归属(没有对应的按下时返回 nil)。
    mutating func longPressed(_ key: DeviceKey) -> Owner? {
        guard var press = presses[key], press.owner != .ignored else { return nil }
        press.longFired = true
        presses[key] = press
        return press.owner
    }

    /// 松开:返回归属以及这次是否算"短按"(松开前没有触发长按)。
    mutating func ended(_ key: DeviceKey) -> (owner: Owner, isTap: Bool)? {
        guard let press = presses.removeValue(forKey: key), press.owner != .ignored else { return nil }
        return (press.owner, !press.longFired)
    }

    /// 在接下来的 `duration` 内忽略该键的新按下(模态界面关闭后防抖)。
    mutating func lockOut(_ key: DeviceKey, for duration: TimeInterval, from time: Date = Date()) {
        lockouts[key] = time.addingTimeInterval(duration)
    }

    /// 链路断开或设备重启时清空(避免残留"按下中"的状态)。
    mutating func reset() {
        presses.removeAll()
        lockouts.removeAll()
    }
}
