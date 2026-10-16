import Foundation

// Passport 设备模块对外暴露的值类型。都标为 nonisolated:
// 既要在主 actor(DeviceLink、界面)上用,也要在串口 / 麦克风后台队列上的协议解析里用。

/// 设备按键(协议 `k` 字段)。
nonisolated enum DeviceKey: String, Sendable { case ok, up, down }

/// 按键事件(协议 `e` 字段):按下瞬间 / 松开 / 按住 1 秒。
nonisolated enum DeviceKeyEvent: String, Sendable { case down, up, long }

/// 设备界面状态(`state` 命令的 `st`),含义见 docs/protocol.md。
nonisolated enum DeviceUIState: String, Sendable { case idle, rec, proc, done, err, sub, list }

/// 设备模式卡片(`state` 命令的 `mode`):听写 / 翻译听写 / 字幕。
nonisolated enum DeviceMode: String, Sendable { case dict, tr, sub }

/// 编程 Agent 通知(`agent` 命令的 `ev`):任务完成 / 等待确认或输入 / 撤销通知。
nonisolated enum DeviceAgentEvent: String, Sendable { case done, input, clear }

/// `config` 命令携带的设置。`clock` 不在这里,由 DeviceLink 发送时现取本地时间。
nonisolated struct DeviceConfig: Equatable, Sendable {
    /// 听写音源是 Passport 麦克风(线上 `mic`)。为 true 时设备在 OK 按下瞬间就开始推音频。
    var passportMic: Bool
    /// 主页底部显示的引擎名,发送前转 ASCII 并截到 23 字节。
    var engine: String
    /// 空闲多少秒熄屏,0 为永不(线上 `screen_off`)。
    var screenOff: Int
    /// 开始 / 结束提示音。
    var sound: Bool
}

/// 模块内部用的链路类型。`DeviceLink.Connection` 是主 actor 上的公开状态,
/// 后台队列(麦克风解码)需要一个 nonisolated 的等价物。
nonisolated enum DeviceLinkKind: String, Sendable {
    case usb
    case ble
}

/// 设备右侧按键提示用的图标 ID(`keys` 命令的取值,固件用图标字体渲染)。列表与 docs/protocol.md 一致。
nonisolated enum DeviceIcon: String, CaseIterable, Sendable {
    case enter, esc, undo, stab, tab, send, stop, cancel, check, `repeat`, mode, apps, mic, translate, hide, up, down, play, open
}
