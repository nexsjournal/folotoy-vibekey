import AppKit
import UniformTypeIdentifiers

/// 字幕记录的保存:询问是否保存、让用户在系统保存面板里选择位置、写成 UTF-8 文本文件。
/// app 自己不保存任何历史记录——记录只在内存里,下一次开始字幕或退出 app 后就清除。
@MainActor
enum TranscriptSaver {
    /// 结束字幕后询问是否保存(模态提示框,标准 macOS 做法)。
    /// 勾选"不再询问"会关闭 `askToSaveCaptions`,之后可在 设置 › 实时字幕 里重新打开。
    /// - Returns: 用户是否成功保存了文件。
    static func askToSave(_ transcript: CaptionTranscript, settings: AppSettings) -> Bool {
        // 已经有一个询问框开着(例如用 Passport 又开又停了一场):不叠加新的模态框。
        // 这场的记录仍在内存里,可以从"字幕记录"窗口保存。
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }
        let alert = NSAlert()
        alert.messageText = String(localized: "保存这次的字幕吗？", bundle: .l10n)
        alert.informativeText = String(localized: "\(transcript.appName) · \(transcript.entries.count) 句。不保存的话，下次开始字幕或退出 InputBetter 后记录会被清除。", bundle: .l10n)
        alert.addButton(withTitle: String(localized: "保存…", bundle: .l10n))
        alert.addButton(withTitle: String(localized: "不保存", bundle: .l10n))
        // "不保存"响应 Esc,避免误按回车丢掉记录:默认按钮是"保存…"。
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "不再询问", bundle: .l10n)
        // 菜单栏应用需要先激活,提示框才会出现在最前面并获得键盘焦点。
        NSApp.activate()
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { settings.askToSaveCaptions = false }
        guard response == .alertFirstButtonReturn else { return false }
        return save(transcript)
    }

    /// 弹出保存面板(模态),写入用户选择的位置。
    static func save(_ transcript: CaptionTranscript) -> Bool {
        let panel = makePanel(for: transcript)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(transcript, to: url, window: nil)
    }

    /// 在窗口上以表单(sheet)形式弹出保存面板,不阻塞其他窗口。
    static func save(_ transcript: CaptionTranscript, in window: NSWindow) async -> Bool {
        let panel = makePanel(for: transcript)
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
        return write(transcript, to: url, window: window)
    }

    /// 是否正在显示"保存这次的字幕吗?"询问框。
    private(set) static var isAsking = false

    // MARK: - 内部

    private static func makePanel(for transcript: CaptionTranscript) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = String(localized: "保存字幕", bundle: .l10n)
        panel.nameFieldStringValue = transcript.suggestedFileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel
    }

    /// 原子写入;失败时用系统错误提示框说明原因。
    private static func write(_ transcript: CaptionTranscript, to url: URL, window: NSWindow?) -> Bool {
        do {
            try transcript.plainText().write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return false
        }
    }
}
