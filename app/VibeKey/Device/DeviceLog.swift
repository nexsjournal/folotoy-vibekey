import os

/// 设备模块的日志。用
/// `log stream --predicate 'subsystem == "local.folobutton.dev" && category == "device"'` 查看。
/// Logger 线程安全,任意队列都可直接使用。
nonisolated enum DeviceLog {
    static let link = Logger(subsystem: "local.folobutton.dev", category: "device")
}
