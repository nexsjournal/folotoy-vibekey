import AppKit
import UniformTypeIdentifiers

/// 字幕记录的保存:在字幕记录窗口上弹出系统保存面板,用户选择位置,写成 UTF-8 文本文件(附带 AI 总结)。
/// app 自己不保存任何历史记录——记录只在内存里,下一次开始字幕或退出 app 后就清除。
@MainActor
enum TranscriptSaver {
    /// 在窗口上以表单(sheet)形式弹出保存面板,不阻塞其他窗口。
    /// - Parameter includeTranslation: 是否带上译文(记录窗口隐藏了译文时不带)。
    static func save(_ transcript: CaptionTranscript, summary: String, includeTranslation: Bool = true, in window: NSWindow) async -> Bool {
        let panel = makePanel(for: transcript)
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
        return write(transcript, summary: summary, includeTranslation: includeTranslation, to: url, window: window)
    }

    // MARK: - 内部

    private static func makePanel(for transcript: CaptionTranscript) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = String(localized: "保存字幕记录", bundle: .l10n)
        panel.nameFieldStringValue = transcript.suggestedFileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel
    }

    /// 原子写入;失败时用系统错误提示框说明原因。
    private static func write(_ transcript: CaptionTranscript, summary: String, includeTranslation: Bool,
                              to url: URL, window: NSWindow?) -> Bool {
        do {
            try transcript.plainText(includeTranslation: includeTranslation, summary: summary).write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return false
        }
    }
}
