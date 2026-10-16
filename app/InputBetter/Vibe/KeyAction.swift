import Foundation

/// Passport 上下键可以映射的动作,围绕 vibe coding(和 Claude Code、Cursor 等 AI 编程工具对话)设计。
nonisolated enum KeyAction: String, CaseIterable, Identifiable, Sendable {
    case none
    /// 回车:发送 prompt / 确认。
    case enter
    /// Esc:打断 Agent / 取消。
    case escape
    /// ⌘Z:撤销刚输入的文字。
    case undo
    /// ⌫ 退格:删除光标前一个字符,说错时在 Passport 上直接回退。
    case backspace
    /// ⌦ 向后删除(Delete):删除光标后一个字符。
    case forwardDelete
    /// ⇧Tab:Claude Code 里切换自动接受 / 计划模式。
    case shiftTab
    case tab
    /// ⌘↩:Cursor 等编辑器里提交。
    case cmdEnter
    /// ⌃C:终端里中断。
    case ctrlC
    /// 输入 "1" 并回车:Claude Code 权限确认选第一项。
    case approve
    /// 再次输入上一次听写的文字。
    case pasteLast
    /// 切换设备模式(听写 → 翻译 → 字幕)。
    case nextMode
    /// 在 Passport 上打开"切换应用"列表,选中后把该应用窗口前置并聚焦。
    case appSwitcher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "无", bundle: .l10n)
        case .enter: String(localized: "回车（发送）", bundle: .l10n)
        case .escape: String(localized: "Esc（打断）", bundle: .l10n)
        case .undo: String(localized: "⌘Z 撤销", bundle: .l10n)
        case .backspace: String(localized: "⌫ 退格（删除前一个字）", bundle: .l10n)
        case .forwardDelete: String(localized: "⌦ Delete（删除后一个字）", bundle: .l10n)
        case .shiftTab: String(localized: "⇧Tab（切换模式）", bundle: .l10n)
        case .tab: "Tab"
        case .cmdEnter: String(localized: "⌘↩ 提交", bundle: .l10n)
        case .ctrlC: String(localized: "⌃C 中断", bundle: .l10n)
        case .approve: String(localized: "确认第一项（1 + 回车）", bundle: .l10n)
        case .pasteLast: String(localized: "再次输入上一段", bundle: .l10n)
        case .nextMode: String(localized: "切换设备模式", bundle: .l10n)
        case .appSwitcher: String(localized: "切换应用", bundle: .l10n)
        }
    }

    /// 设备屏幕右侧的提示图标(nil = 无动作,隐藏提示)。
    var deviceIcon: DeviceIcon? {
        switch self {
        case .none: nil
        case .enter: .enter
        case .escape: .esc
        case .undo: .undo
        case .backspace: .bksp
        case .forwardDelete: .del
        case .shiftTab: .stab
        case .tab: .tab
        case .cmdEnter: .send
        case .ctrlC: .stop
        case .approve: .check
        case .pasteLast: .repeat
        case .nextMode: .mode
        case .appSwitcher: .apps
        }
    }
}
