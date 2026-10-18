import AppKit
import Carbon.HIToolbox

/// 把文本输入到当前聚焦的输入框:写剪贴板 → 模拟 ⌘V → 稍后恢复原剪贴板。
/// 这是兼容性最好的方式(原生、Electron、浏览器、终端都可用)。
/// 线程:主线程。`insert` 发出 ⌘V 后立即返回,恢复剪贴板在独立任务里延迟进行;
/// 用"待恢复快照"串行化:上一次的恢复还没做完又来一次输入时,沿用那份快照(剪贴板里此时是我们写入的听写文本,
/// 不能当成用户的内容保存),避免把听写文本"恢复"回剪贴板。
@MainActor
final class TextInserter {
    enum Outcome: Equatable {
        case pasted
        /// 没能粘贴,文本已留在剪贴板;附带原因。
        case copied(CopyReason)
    }

    /// 剪贴板的完整内容(每个条目的所有类型)。
    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    /// 一次还没完成的剪贴板恢复。
    private struct PendingRestore {
        /// 要恢复成的用户原内容。
        let snapshot: Snapshot
        /// 写入听写文本后剪贴板的 changeCount:恢复时还是它,说明期间没有别人改过剪贴板。
        let changeCount: Int
        let task: Task<Void, Never>
    }

    /// 恢复剪贴板前的等待时间:目标应用需要先读完剪贴板。
    private let restoreDelay: Duration = .milliseconds(700)
    private var pendingRestore: PendingRestore?

    func insert(_ text: String, target: NSRunningApplication?) async -> Outcome {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else { return copyOnly(text, to: pasteboard, reason: .noAccessibility) }
        if IsSecureEventInputEnabled() { return copyOnly(text, to: pasteboard, reason: .secureInput) }
        if let target, NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            return copyOnly(text, to: pasteboard, reason: .windowChanged)
        }

        // 上一次的恢复还没做,且剪贴板里仍是我们写入的内容:沿用那份用户原内容的快照。
        let saved: Snapshot
        if let pending = pendingRestore, pasteboard.changeCount == pending.changeCount {
            saved = pending.snapshot
        } else {
            saved = snapshot(pasteboard)
        }
        pendingRestore?.task.cancel()
        copy(text, to: pasteboard)
        let ourChange = pasteboard.changeCount
        postPaste()

        let delay = restoreDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.finishRestore(saved, changeCount: ourChange)
        }
        pendingRestore = PendingRestore(snapshot: saved, changeCount: ourChange, task: task)
        return .pasted
    }

    /// 延迟到点:期间用户或其他应用又复制了内容,就不再覆盖。
    private func finishRestore(_ saved: Snapshot, changeCount: Int) {
        guard pendingRestore?.changeCount == changeCount else { return }
        pendingRestore = nil
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == changeCount { restore(saved, to: pasteboard) }
    }

    /// 不能粘贴:文字留在剪贴板让用户自己粘贴。之前排着的恢复作废(否则会把这段文字冲掉)。
    private func copyOnly(_ text: String, to pasteboard: NSPasteboard, reason: CopyReason) -> Outcome {
        pendingRestore?.task.cancel()
        pendingRestore = nil
        copy(text, to: pasteboard)
        return .copied(reason)
    }

    // MARK: - 剪贴板

    private func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private func restore(_ items: Snapshot, to pasteboard: NSPasteboard) {
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
