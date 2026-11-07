import AppKit
import ApplicationServices

/// 通过 macOS Accessibility 读取当前 Agent 的项目 / 会话，并在用户确认后按下对应行。
///
/// 约束：
/// - 只在主线程读取 AX；每次操作前重新读取，不缓存 AXUIElement；
/// - 只读侧栏标题、窗口标题和控件角色，不读取或记录聊天正文；
/// - 项目 / 会话名称只用于设备显示，不写日志、不持久化；
/// - 未登记的 Agent 走 `GenericAgentSessionAdapter`，不做 Bundle ID 白名单。
@MainActor
enum AgentSessionCatalogLoader {
    static let deepSeekBundleID = DeepSeekAgentSessionAdapter.bundleID

    static var supportedBundleIDs: Set<String> {
        Set(AgentSessionRegistry.known.flatMap { $0.bundleIDs })
    }

    /// 是否有专门适配器。只用于调试 / 提示；是否能读侧栏由实际 AX 探测决定。
    static func supports(_ bundleID: String?) -> Bool {
        AgentSessionRegistry.isKnown(bundleID)
    }

    /// 读取当前 App 的项目与会话。会先把目标 App 前置并开启 Electron 的 AX 树；
    /// 失败时返回 nil，调用方回退到普通「切换应用」列表。
    static func load(for app: AgentSessionApp) async -> AgentSessionCatalog? {
        guard AXIsProcessTrusted(), let running = await activate(app) else { return nil }
        guard running.bundleIdentifier == app.bundleID else { return nil }
        let adapter = AgentSessionRegistry.adapter(for: app.bundleID)
        // Chromium / Electron 首次建 AX 树可能比 260 ms 慢；只在拿不到结果时重试。
        // 冷启动的 Electron 首次建树可能 3 秒以上；只有 notReady 才等，普通应用会立刻 return。
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            try? Task.checkCancellation()
            switch await adapter.probeCatalog(for: app) {
            case .found(let catalog):
                if !catalog.isEmpty { return catalog }
            case .notAgent:
                // 树已经读全但没有聊天输入框 / 侧栏：普通应用，立刻回退，不再空等。
                return nil
            case .notReady:
                break
            }
            try? await Task.sleep(for: .milliseconds(320))
        } while ContinuousClock.now < deadline
        return nil
    }

    /// 读取某个项目的会话。折叠的项目会先展开再读。
    static func sessions(for project: AgentProject, in app: AgentSessionApp) async -> [AgentSession] {
        guard let running = await activate(app) else { return [] }
        guard running.bundleIdentifier == app.bundleID else { return [] }
        return await AgentSessionRegistry.adapter(for: app.bundleID)
            .loadSessions(for: project, in: app)
    }

    /// 打开项目或最近列表中的一个会话，并在切换完成后把焦点放回输入框。
    /// 最近列表的 `project` 为 nil。
    static func open(project: AgentProject?, session: AgentSession, in app: AgentSessionApp) async -> Bool {
        guard let running = await activate(app) else { return false }
        let adapter = AgentSessionRegistry.adapter(for: app.bundleID)
        guard await adapter.open(project: project, session: session, in: app) else { return false }
        if session.index != AgentSession.newChatIndex {
            if AgentSessionRegistry.isKnown(app.bundleID) {
                // Codex / DSH 的窗口标题会切成会话名，用标题确认切换完成。
                await waitForWindowTitle(session.name, app: app)
            } else {
                // ZCode / WorkBuddy 的窗口标题固定，等一下渲染后直接聚焦输入框。
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return await focusInput(running)
    }

    // MARK: - 通用

    private static func activate(_ app: AgentSessionApp) async -> NSRunningApplication? {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else {
            return nil
        }
        try? Task.checkCancellation()
        running.activate(options: [.activateAllWindows])
        let element = AXUIElementCreateApplication(app.pid)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = ElectronAccessibility.enable(processID: app.pid)
        try? await Task.sleep(for: .milliseconds(260))
        try? Task.checkCancellation()
        return running
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let focused = AgentAX.element(AgentAX.value(app, kAXFocusedWindowAttribute)) {
            return focused
        }
        let windows = AgentAX.elements(AgentAX.value(app, kAXWindowsAttribute))
        return windows.first { AgentAX.bool($0, kAXMinimizedAttribute) != true } ?? windows.first
    }

    private static func focusInput(_ running: NSRunningApplication) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if AppSwitcher.focusTextInput(in: running) { return true }
            if running.bundleIdentifier == AccessibilityCodexDesktopAdapter.bundleIdentifier,
               (try? await AccessibilityCodexDesktopAdapter().inspectTarget()) != nil {
                return true
            }
            // 通用回退：窗口里可能不止一个 text area，AppSwitcher 会放弃；这里按解析出的主输入框聚焦。
            if let window = focusedWindow(of: running.processIdentifier) {
                let snapshot = AXSnapshot.capture(window: window, maxDepth: 40, maxNodes: 6_000)
                if let composer = AgentNavigationParser.findComposer(snapshot),
                   let element = AgentAX.element(at: composer.path, in: window),
                   AXUIElementSetAttributeValue(
                    element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(90))
        } while ContinuousClock.now < deadline
        return false
    }

    private static func waitForWindowTitle(_ name: String, app: AgentSessionApp) async {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if let window = focusedWindow(of: app.pid) {
                let title = AgentAX.string(window, kAXTitleAttribute)
                if AgentSessionNameMatcher.matches(windowTitle: title, sessionName: name) {
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        } while ContinuousClock.now < deadline
    }
}
