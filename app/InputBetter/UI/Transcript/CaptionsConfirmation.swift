import AppKit

/// 结束字幕 / 换应用 / 退出 app 时的确认框(模态提示框,标准 macOS 做法)。
/// 结束时只确认"是否结束";保存、总结由用户在字幕记录窗口里自己处理,结束时不再追问。
/// 换应用会清掉当前记录,所以有未保存内容时单独说明并给出"先打开字幕记录"的选择。
@MainActor
enum CaptionsConfirmation {
    /// 是否正在显示确认框(避免叠加多个模态框)。
    private(set) static var isAsking = false

    /// 确认结束字幕。勾选"不再询问"会关闭 `confirmStopCaptions`,之后可在 设置 › 实时字幕 里重新打开。
    /// - Returns: 用户是否确认结束。
    static func confirmStop(appName: String, sentences: Int, settings: AppSettings) -> Bool {
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        let alert = NSAlert()
        alert.messageText = String(localized: "结束字幕？", bundle: .l10n)
        alert.informativeText = String(localized: "\(appName) · \(sentences) 句。结束后可以在字幕记录窗口里查看、总结和保存。", bundle: .l10n)
        alert.addButton(withTitle: String(localized: "结束", bundle: .l10n))
        alert.addButton(withTitle: String(localized: "取消", bundle: .l10n))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "不再询问", bundle: .l10n)
        // 菜单栏应用需要先激活,提示框才会出现在最前面并获得键盘焦点。
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on { settings.confirmStopCaptions = false }
        return confirmed
    }

    /// 换应用时的选择。
    enum SwitchChoice {
        /// 结束当前字幕,开始新应用的字幕(当前记录被替换)。
        case switchApp
        /// 先不换,打开字幕记录窗口(用户可以先保存当前记录)。
        case openTranscript
        case cancel
    }

    /// 字幕进行中换成另一个应用,且当前记录还有没保存的内容:说明记录会被替换,让用户决定。
    /// 不受"不再询问"影响(会丢内容的操作每次都确认)。
    static func confirmSwitch(from oldApp: String, to newApp: String, sentences: Int) -> SwitchChoice {
        guard !isAsking else { return .cancel }
        isAsking = true
        defer { isAsking = false }
        let alert = NSAlert()
        alert.messageText = String(localized: "改为转录「\(newApp)」？", bundle: .l10n)
        alert.informativeText = String(localized: "「\(oldApp)」的这场字幕记录（\(sentences) 句）还没保存，开始新的字幕后会被替换。需要保留的话，先打开字幕记录保存。", bundle: .l10n)
        let switchButton = alert.addButton(withTitle: String(localized: "切换", bundle: .l10n))
        switchButton.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "打开字幕记录", bundle: .l10n))
        alert.addButton(withTitle: String(localized: "取消", bundle: .l10n))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .switchApp
        case .alertSecondButtonReturn: return .openTranscript
        default: return .cancel
        }
    }

    /// 字幕还在进行时退出 app:确认一次(记录只在内存里,退出后就没了)。
    static func confirmQuit(appName: String) -> Bool {
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        let alert = NSAlert()
        alert.messageText = String(localized: "字幕正在进行，确定退出吗？", bundle: .l10n)
        alert.informativeText = String(localized: "退出后 \(appName) 的这场字幕记录会被清除。需要的话，先在字幕记录窗口里保存。", bundle: .l10n)
        alert.addButton(withTitle: String(localized: "退出", bundle: .l10n))
        alert.addButton(withTitle: String(localized: "取消", bundle: .l10n))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
