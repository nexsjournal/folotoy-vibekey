import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 通过官方本地会话链接打开聊天，再读回实际激活的聊天，避免仅凭窗口标题判断。
@MainActor
final class CodexThreadNavigator {
    struct ActiveChat: Equatable {
        let threadID: UUID?
        let target: CodexDraftTarget
    }

    private let clipboard: TextInserter
    private let codex: CodexActionCoordinator
    private let workspace = NSWorkspace.shared

    init(clipboard: TextInserter, codex: CodexActionCoordinator) {
        self.clipboard = clipboard
        self.codex = codex
    }

    nonisolated static func link(to id: UUID) -> URL {
        URL(string: "codex://threads/\(id.uuidString.lowercased())")!
    }

    nonisolated static func threadID(from text: String) -> UUID? {
        guard let parts = URLComponents(string: text), parts.scheme == "codex", parts.host == "threads",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil, parts.path.count == 37,
              parts.path.hasPrefix("/") else { return nil }
        return UUID(uuidString: String(parts.path.dropFirst()))
    }

    /// 等待深链接渲染完成。读到其他会话时继续等，直到原会话和输入框同时就绪。
    @discardableResult
    func open(_ threadID: UUID) async throws -> ActiveChat {
        guard let url = workspace.urlForApplication(withBundleIdentifier: AccessibilityCodexDesktopAdapter.bundleIdentifier)
        else { throw DeviceInputTarget.Failure.unavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await workspace.open([Self.link(to: threadID)], withApplicationAt: url, configuration: configuration)
        guard !Task.isCancelled else { throw CancellationError() }
        ElectronAccessibility.enable(processID: app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            try Task.checkCancellation()
            if workspace.frontmostApplication?.processIdentifier == app.processIdentifier {
                if AppSwitcher.focusTextInput(in: app), let chat = try? await currentChat(),
                   chat.threadID == threadID {
                    Log.codex.info("follow-up: original chat and composer ready")
                    return chat
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw DeviceInputTarget.Failure.noInput
    }

    /// 开始录音时恢复当前前台 Codex 的输入焦点，用户手动切换后以新会话为准。
    func prepareCurrentChat() async throws -> ActiveChat {
        guard let app = workspace.frontmostApplication,
              app.bundleIdentifier == AccessibilityCodexDesktopAdapter.bundleIdentifier else {
            throw DeviceInputTarget.Failure.noInput
        }
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            try Task.checkCancellation()
            guard workspace.frontmostApplication?.processIdentifier == app.processIdentifier else { break }
            if let chat = try? await currentChat() {
                return chat
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw DeviceInputTarget.Failure.noInput
    }

    /// 新对话可能还没有深链接。始终读取并核对同一输入节点，有链接时一并绑定。
    func currentChat() async throws -> ActiveChat {
        try Task.checkCancellation()
        guard let before = await codex.currentFollowupTarget(), !IsSecureEventInputEnabled() else {
            throw DeviceInputTarget.Failure.noInput
        }
        let key = KeyLayout.keyCode(for: "l") ?? CGKeyCode(kVK_ANSI_L)
        let copied = await clipboard.temporaryCopy(trigger: { [workspace] in
            guard workspace.frontmostApplication?.processIdentifier == before.processID else { return false }
            return KeySender.press(Int(key), flags: [.maskCommand, .maskAlternate], processID: before.processID)
        }, parse: Self.threadID(from:))
        try Task.checkCancellation()
        guard await codex.currentFollowupTarget() == before else {
            throw DeviceInputTarget.Failure.noInput
        }
        return ActiveChat(threadID: copied, target: before)
    }
}
