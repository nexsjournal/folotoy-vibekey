import AppKit
import Carbon.HIToolbox

/// 把文本输入到当前聚焦的输入框:写剪贴板 → 模拟 ⌘V → 稍后恢复原剪贴板。
/// 这是兼容性最好的方式(原生、Electron、浏览器、终端都可用)。
@MainActor
final class TextInserter {
    enum Outcome: Equatable {
        case pasted
        /// 没能粘贴,文本已留在剪贴板;附带原因。
        case copied(CopyReason)
    }

    /// 恢复剪贴板前的等待时间:目标应用需要先读完剪贴板。
    private let restoreDelay: Duration = .milliseconds(700)

    func insert(_ text: String, target: NSRunningApplication?) async -> Outcome {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            copy(text, to: pasteboard)
            return .copied(.noAccessibility)
        }
        if IsSecureEventInputEnabled() {
            copy(text, to: pasteboard)
            return .copied(.secureInput)
        }
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            copy(text, to: pasteboard)
            return .copied(.windowChanged)
        }

        let saved = snapshot(pasteboard)
        copy(text, to: pasteboard)
        let ourChange = pasteboard.changeCount
        postPaste()

        try? await Task.sleep(for: restoreDelay)
        // 期间用户或其他应用又复制了内容,就不再覆盖。
        if pasteboard.changeCount == ourChange {
            restore(saved, to: pasteboard)
        }
        return .pasted
    }

    // MARK: - 剪贴板

    private func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let objects = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(objects)
    }

    // MARK: - 模拟按键

    /// ⌘V:键码按当前键盘布局解析(Dvorak 等布局下 V 不在 ANSI 位置)。
    private func postPaste() {
        KeySender.press(Int(KeyLayout.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)), flags: .maskCommand)
    }
}
