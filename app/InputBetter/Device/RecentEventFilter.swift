import Foundation

/// 按 `(boot, seq)` 去重最近的设备事件,防止重传或 USB/BLE 切换导致一次按键触发两次。
nonisolated struct RecentEventFilter: Sendable {
    private struct Key: Hashable, Sendable {
        var boot: String
        var seq: Int
    }

    private let capacity: Int
    private var order: [Key] = []
    private var seen: Set<Key> = []

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// 首次出现返回 true;最近 `capacity` 个事件内重复出现返回 false。
    mutating func accept(boot: String, seq: Int) -> Bool {
        let key = Key(boot: boot, seq: seq)
        guard seen.insert(key).inserted else { return false }
        order.append(key)
        if order.count > capacity {
            seen.remove(order.removeFirst())
        }
        return true
    }

    /// seq 缺失的事件无法去重,直接接受。
    mutating func accept(_ report: DeviceKeyReport) -> Bool {
        guard let seq = report.seq else { return true }
        return accept(boot: report.boot, seq: seq)
    }

    mutating func reset() {
        order.removeAll()
        seen.removeAll()
    }
}
