import AppKit
import ApplicationServices

/// 一个支持项目 / 会话导航的 Agent App。只保留跨异步任务需要的标识，AX 元素在每次操作前重新读取。
nonisolated struct AgentSessionApp: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String
    let name: String

    init(pid: pid_t, bundleID: String, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }

    @MainActor init?(running: NSRunningApplication) {
        guard let bundleID = running.bundleIdentifier, !running.isTerminated else { return nil }
        self.init(pid: running.processIdentifier, bundleID: bundleID,
                  name: running.localizedName ?? bundleID)
    }

    /// 设备列表标题尽量短，同时让用户知道当前在操作哪个 Agent。
    var shortName: String {
        switch bundleID {
        case "com.openai.codex": "CODEX"
        case "ai.deepseek.dsh.desktop.next": "DSH"
        default: String(name.prefix(8)).uppercased()
        }
    }

    /// 写入「设置 › Passport › 目标应用」的显示名；Codex 的 localizedName 是 ChatGPT，这里用产品名。
    var targetName: String {
        switch bundleID {
        case "com.openai.codex": "Codex"
        case "ai.deepseek.dsh.desktop.next": "DeepSeek"
        default: name
        }
    }
}

/// 侧栏里的一个会话。`index` 是该会话在当前项目 / 最近列表中的顺序，用来在 AX 树刷新后重新定位。
nonisolated struct AgentSession: Equatable, Sendable {
    static let newChatIndex = -1

    let name: String
    let index: Int
    let isCurrent: Bool

    var displayName: String { isCurrent ? "* \(name)" : name }
}

/// 侧栏里的一个项目 / 工作区。项目本身可能暂时没有会话，选择后再读取其会话列表。
nonisolated struct AgentProject: Equatable, Sendable {
    let name: String
    let index: Int
    let sessions: [AgentSession]
    let isCurrent: Bool

    var displayName: String { isCurrent ? "* \(name)" : name }
}

/// 项目列表中的固定选项或真实项目。
nonisolated enum AgentProjectChoice: Equatable, Sendable {
    case switchApp
    case recent
    case project(AgentProject)

    var displayName: String {
        switch self {
        case .switchApp: "SWITCH APP"
        case .recent: "RECENT"
        case .project(let project): project.displayName
        }
    }
}

nonisolated struct AgentSessionCatalog: Equatable, Sendable {
    let app: AgentSessionApp
    let projects: [AgentProject]
    let recent: [AgentSession]

    var isEmpty: Bool { projects.isEmpty && recent.isEmpty }
}

/// 只做纯字符串判断，便于单测；窗口标题在 Codex 与 DSH 上都可能带应用后缀。
nonisolated enum AgentSessionNameMatcher {
    static func normalizedWindowTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: " — DeepSeek Harness", with: "")
            .replacingOccurrences(of: " - DeepSeek Harness", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(windowTitle: String, sessionName: String) -> Bool {
        let title = normalizedWindowTitle(windowTitle)
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !name.isEmpty else { return false }
        if title == name { return true }
        guard name.count >= 2 else { return false }
        if title.hasPrefix(name + " ") || title.hasSuffix(" " + name) { return true }
        // 短标题用 contains 容易误判（例如 "A"），只在名称足够长时接受包含关系。
        return name.count >= 4 && title.contains(name)
    }
}

/// 通过 macOS Accessibility 读取 Codex / DeepSeek Honeycomb 的侧栏，并在用户确认后按下对应行。
///
/// 约束：
/// - 只在主线程读取 AX；每次操作前重新读取，不缓存 AXUIElement；
/// - 只读取侧栏标题、窗口标题和控件角色，不读取或记录聊天正文；
/// - 项目 / 会话名称只用于设备显示，不写日志、不持久化。
@MainActor
enum AgentSessionCatalogLoader {
    static let deepSeekBundleID = "ai.deepseek.dsh.desktop.next"
    static let supportedBundleIDs: Set<String> = [
        AccessibilityCodexDesktopAdapter.bundleIdentifier,
        deepSeekBundleID,
    ]

    static func supports(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return supportedBundleIDs.contains(bundleID)
    }

    /// 读取当前 App 的项目与会话。会先把目标 App 前置并开启 Electron 的 AX 树；
    /// 失败时返回 nil，调用方回退到普通「切换应用」列表。
    static func load(for app: AgentSessionApp) async -> AgentSessionCatalog? {
        guard let running = await activate(app) else { return nil }
        switch app.bundleID {
        case AccessibilityCodexDesktopAdapter.bundleIdentifier:
            return codexCatalog(app: app, running: running)
        case deepSeekBundleID:
            return deepSeekCatalog(app: app, running: running)
        default:
            return nil
        }
    }

    /// 读取某个项目的会话。Codex / DSH 的项目在侧栏里可能处于折叠状态，这里会按需展开。
    static func sessions(for project: AgentProject, in app: AgentSessionApp) async -> [AgentSession] {
        guard let running = await activate(app) else { return [] }
        switch app.bundleID {
        case AccessibilityCodexDesktopAdapter.bundleIdentifier:
            return await codexSessions(for: project, app: app, running: running)
        case deepSeekBundleID:
            return await deepSeekSessions(for: project, app: app, running: running)
        default:
            return []
        }
    }

    /// 打开项目或最近列表中的一个会话，并在切换完成后把焦点放回输入框。
    /// 最近列表的 `project` 为 nil。
    static func open(project: AgentProject?, session: AgentSession, in app: AgentSessionApp) async -> Bool {
        guard let running = await activate(app) else { return false }
        let opened: Bool
        switch app.bundleID {
        case AccessibilityCodexDesktopAdapter.bundleIdentifier:
            opened = await openCodex(project: project, session: session, app: app, running: running)
        case deepSeekBundleID:
            opened = await openDeepSeek(project: project, session: session, app: app, running: running)
        default:
            opened = false
        }
        guard opened else { return false }
        if session.index != AgentSession.newChatIndex {
            await waitForWindowTitle(session.name, app: app, running: running)
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
        try? await Task.sleep(for: .milliseconds(220))
        try? Task.checkCancellation()
        return running
    }

    private static func focusInput(_ running: NSRunningApplication) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if AppSwitcher.focusTextInput(in: running) { return true }
            if running.bundleIdentifier == AccessibilityCodexDesktopAdapter.bundleIdentifier,
               (try? await AccessibilityCodexDesktopAdapter().inspectTarget()) != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(80))
        } while ContinuousClock.now < deadline
        return false
    }

    private static func waitForWindowTitle(_ name: String, app: AgentSessionApp, running: NSRunningApplication) async {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if let title = windowTitle(of: running),
               AgentSessionNameMatcher.matches(windowTitle: title, sessionName: name) {
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
        } while ContinuousClock.now < deadline
    }

    private static func windowTitle(of running: NSRunningApplication) -> String? {
        guard let window = focusedWindow(of: running) else { return nil }
        return AXTree.string(window, kAXTitleAttribute)
    }

    private static func focusedWindow(of running: NSRunningApplication) -> AXUIElement? {
        let app = AXUIElementCreateApplication(running.processIdentifier)
        if let focused = AXTree.element(AXTree.value(app, kAXFocusedWindowAttribute)) {
            return focused
        }
        let windows = AXTree.elements(AXTree.value(app, kAXWindowsAttribute))
        return windows.first { AXTree.bool($0, kAXMinimizedAttribute) != true } ?? windows.first
    }

    // MARK: - Codex

    private static func codexCatalog(app: AgentSessionApp, running: NSRunningApplication) -> AgentSessionCatalog? {
        guard let window = focusedWindow(of: running) else { return nil }
        let title = AXTree.string(window, kAXTitleAttribute)
        let groups = codexProjectGroups(in: window)
        let projects = groups.enumerated().map { index, group in
            let name = AXTree.string(group, kAXTitleAttribute)
            let sessions = codexSessionButtons(in: group, projectName: name).enumerated().map { offset, button in
                let sessionName = AXTree.string(button, kAXTitleAttribute)
                return AgentSession(name: sessionName, index: offset,
                                    isCurrent: AgentSessionNameMatcher.matches(windowTitle: title, sessionName: sessionName))
            }
            return AgentProject(name: name, index: index, sessions: sessions,
                                isCurrent: sessions.contains(where: \.isCurrent))
        }
        return AgentSessionCatalog(app: app, projects: projects,
                                   recent: codexRecentSessions(in: window, windowTitle: title))
    }

    private static func codexProjectGroups(in window: AXUIElement) -> [AXUIElement] {
        AXTree.all(in: window) { element in
            guard AXTree.string(element, kAXRoleAttribute) == "AXGroup" else { return false }
            let title = AXTree.string(element, kAXTitleAttribute)
            guard !title.isEmpty, title == AXTree.string(element, kAXDescriptionAttribute) else { return false }
            return !AXTree.all(in: element, maxDepth: 3) { child in
                AXTree.string(child, kAXRoleAttribute) == "AXButton"
                    && AXTree.string(child, kAXTitleAttribute) == title
            }.isEmpty
        }
    }

    private static func codexProjectGroup(in window: AXUIElement, index: Int, name: String?) -> AXUIElement? {
        let groups = codexProjectGroups(in: window)
        guard index >= 0, index < groups.count else { return nil }
        let group = groups[index]
        if let name, AXTree.string(group, kAXTitleAttribute) != name { return nil }
        return group
    }

    private static func codexProjectButton(in group: AXUIElement) -> AXUIElement? {
        let name = AXTree.string(group, kAXTitleAttribute)
        return AXTree.all(in: group, maxDepth: 4) { element in
            AXTree.string(element, kAXRoleAttribute) == "AXButton"
                && AXTree.string(element, kAXTitleAttribute) == name
        }.first
    }

    private static func codexStartNewChatButton(in group: AXUIElement, projectName: String) -> AXUIElement? {
        AXTree.all(in: group) { element in
            AXTree.string(element, kAXRoleAttribute) == "AXButton"
                && AXTree.string(element, kAXTitleAttribute) == "在 \(projectName) 中开始新聊天"
        }.first
    }

    private static func codexSessionButtons(in group: AXUIElement, projectName: String) -> [AXUIElement] {
        AXTree.all(in: group) { element in
            guard AXTree.string(element, kAXRoleAttribute) == "AXButton" else { return false }
            let title = AXTree.string(element, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != projectName else { return false }
            let excluded = ["置顶聊天", "归档聊天", "项目操作", "展开其余", "新聊天"]
            guard !excluded.contains(title) else { return false }
            if title.hasPrefix("在 ") && title.contains("中开始新聊天") { return false }
            return AXTree.hasAction(element, kAXPressAction as String)
        }
    }

    private static func codexRecentSessions(in window: AXUIElement, windowTitle: String) -> [AgentSession] {
        let recentButtons = AXTree.all(in: window, where: { element in
            AXTree.string(element, kAXRoleAttribute) == "AXButton"
                && ["最近", "Recent"].contains(AXTree.string(element, kAXTitleAttribute))
        })
        guard let recent = recentButtons.first else { return [] }
        // 从「最近」按钮往上找最近的、包含会话按钮的 group；避免把整个侧栏的按钮都算进来。
        var node: AXUIElement? = recent
        while let current = node {
            let buttons = AXTree.all(in: current) { element in
                guard AXTree.string(element, kAXRoleAttribute) == "AXButton" else { return false }
                let title = AXTree.string(element, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty,
                      !["新聊天", "聊天侧边栏选项", "置顶聊天", "归档聊天", "最近", "Recent"].contains(title) else {
                    return false
                }
                return AXTree.hasAction(element, kAXPressAction as String)
            }
            if !buttons.isEmpty {
                return buttons.enumerated().map { index, button in
                    let name = AXTree.string(button, kAXTitleAttribute)
                    return AgentSession(name: name, index: index,
                                        isCurrent: AgentSessionNameMatcher.matches(windowTitle: windowTitle, sessionName: name))
                }
            }
            node = AXTree.element(AXTree.value(current, kAXParentAttribute))
        }
        return []
    }

    private static func codexSessions(for project: AgentProject, app: AgentSessionApp,
                                      running: NSRunningApplication) async -> [AgentSession] {
        guard let window = focusedWindow(of: running) else { return [] }
        guard let group = codexProjectGroup(in: window, index: project.index, name: project.name),
              let button = codexProjectButton(in: group) else { return [] }
        if AXTree.bool(button, "AXExpanded") != true {
            _ = AXTree.press(button)
            try? await Task.sleep(for: .milliseconds(220))
        }
        guard let refreshedWindow = focusedWindow(of: running),
              let refreshed = codexProjectGroup(in: refreshedWindow, index: project.index, name: project.name) else {
            return []
        }
        let name = AXTree.string(refreshed, kAXTitleAttribute)
        let title = AXTree.string(refreshedWindow, kAXTitleAttribute)
        let sessions = codexSessionButtons(in: refreshed, projectName: name).enumerated().map { index, element in
            let sessionName = AXTree.string(element, kAXTitleAttribute)
            return AgentSession(name: sessionName, index: index,
                                isCurrent: AgentSessionNameMatcher.matches(windowTitle: title, sessionName: sessionName))
        }
        if sessions.isEmpty, codexStartNewChatButton(in: refreshed, projectName: name) != nil {
            return [AgentSession(name: "NEW CHAT", index: AgentSession.newChatIndex, isCurrent: false)]
        }
        return sessions
    }

    private static func openCodex(project: AgentProject?, session: AgentSession,
                                  app: AgentSessionApp, running: NSRunningApplication) async -> Bool {
        guard let window = focusedWindow(of: running) else { return false }
        if let project {
            guard var group = codexProjectGroup(in: window, index: project.index, name: project.name),
                  let button = codexProjectButton(in: group) else { return false }
            if AXTree.bool(button, "AXExpanded") != true {
                _ = AXTree.press(button)
                try? await Task.sleep(for: .milliseconds(220))
                guard let refreshedWindow = focusedWindow(of: running),
                      let refreshed = codexProjectGroup(in: refreshedWindow, index: project.index, name: project.name) else {
                    return false
                }
                group = refreshed
            }
            let projectName = AXTree.string(group, kAXTitleAttribute)
            if session.index == AgentSession.newChatIndex {
                guard let newChat = codexStartNewChatButton(in: group, projectName: projectName) else { return false }
                return AXTree.press(newChat)
            }
            let buttons = codexSessionButtons(in: group, projectName: projectName)
            let target = buttons.enumerated().first {
                $0.offset == session.index && AXTree.string($0.element, kAXTitleAttribute) == session.name
            }?.element ?? buttons.first { AXTree.string($0, kAXTitleAttribute) == session.name }
            guard let target else { return false }
            return AXTree.press(target)
        }
        // 最近列表：只在最近列表的按钮中找，避免同名项目会话误触。
        let recent = codexRecentSessions(in: window, windowTitle: AXTree.string(window, kAXTitleAttribute))
        guard let match = recent.first(where: { $0.index == session.index && $0.name == session.name })
                ?? recent.first(where: { $0.name == session.name }) else { return false }
        let buttons = codexRecentButtons(in: window)
        let target = buttons[safe: match.index].flatMap {
            AXTree.string($0, kAXTitleAttribute) == match.name ? $0 : nil
        } ?? buttons.first(where: { AXTree.string($0, kAXTitleAttribute) == match.name })
        guard let target else { return false }
        return AXTree.press(target)
    }

    private static func codexRecentButtons(in window: AXUIElement) -> [AXUIElement] {
        let recentButtons = AXTree.all(in: window, where: { element in
            AXTree.string(element, kAXRoleAttribute) == "AXButton"
                && ["最近", "Recent"].contains(AXTree.string(element, kAXTitleAttribute))
        })
        guard let recent = recentButtons.first else { return [] }
        var node: AXUIElement? = recent
        while let current = node {
            let buttons = AXTree.all(in: current) { element in
                guard AXTree.string(element, kAXRoleAttribute) == "AXButton" else { return false }
                let title = AXTree.string(element, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty,
                      !["新聊天", "聊天侧边栏选项", "置顶聊天", "归档聊天", "最近", "Recent"].contains(title) else {
                    return false
                }
                return AXTree.hasAction(element, kAXPressAction as String)
            }
            if !buttons.isEmpty { return buttons }
            node = AXTree.element(AXTree.value(current, kAXParentAttribute))
        }
        return []
    }

    // MARK: - DeepSeek Honeycomb

    private static func deepSeekCatalog(app: AgentSessionApp, running: NSRunningApplication) -> AgentSessionCatalog? {
        guard let window = focusedWindow(of: running) else { return nil }
        let title = AXTree.string(window, kAXTitleAttribute)
        guard let outline = deepSeekOutline(in: window) else { return nil }
        let groups = AXTree.children(outline).filter {
            AXTree.string($0, kAXRoleAttribute) == "AXGroup"
        }
        let projects = groups.enumerated().compactMap { index, group -> AgentProject? in
            let rows = deepSeekRows(in: group)
            guard let first = rows.first else { return nil }
            let projectName = deepSeekRowName(first)
            guard !projectName.isEmpty else { return nil }
            let sessions = rows.dropFirst().enumerated().compactMap { index, row -> AgentSession? in
                let name = deepSeekRowName(row)
                guard !name.isEmpty, name != projectName else { return nil }
                return AgentSession(name: name, index: index,
                                    isCurrent: AgentSessionNameMatcher.matches(windowTitle: title, sessionName: name))
            }
            return AgentProject(name: projectName, index: index, sessions: sessions,
                                isCurrent: sessions.contains(where: \.isCurrent))
        }
        return AgentSessionCatalog(app: app, projects: projects,
                                   recent: Array(projects.flatMap(\.sessions).prefix(20)))
    }

    private static func deepSeekOutline(in window: AXUIElement) -> AXUIElement? {
        let outlines = AXTree.all(in: window) { AXTree.string($0, kAXRoleAttribute) == "AXOutline" }
        return outlines.first { AXTree.string($0, kAXDescriptionAttribute) == "会话" }
            ?? outlines.first { !deepSeekRows(in: $0).isEmpty }
    }

    private static func deepSeekRows(in element: AXUIElement) -> [AXUIElement] {
        AXTree.all(in: element) { AXTree.string($0, kAXRoleAttribute) == "AXRow" }
    }

    private static func deepSeekRowName(_ row: AXUIElement) -> String {
        let texts = AXTree.all(in: row) { element in
            AXTree.string(element, kAXRoleAttribute) == "AXStaticText"
        }.map { AXTree.string($0, kAXValueAttribute) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isStatusOrRelativeTime($0) }
        if let longest = texts.max(by: { $0.count < $1.count }) { return longest }
        return AXTree.string(row, kAXTitleAttribute)
    }

    private static func isStatusOrRelativeTime(_ text: String) -> Bool {
        if ["进行中", "已完成", "等待输入", "等待中", "失败", "刚刚"].contains(text) { return true }
        return text.range(of: #"^\d+\s*(秒|分钟|分|小时|天|周|个月|月|年)$"#, options: .regularExpression) != nil
    }

    private static func deepSeekSessions(for project: AgentProject, app: AgentSessionApp,
                                         running: NSRunningApplication) async -> [AgentSession] {
        guard let window = focusedWindow(of: running),
              let outline = deepSeekOutline(in: window) else { return [] }
        let groups = AXTree.children(outline).filter {
            AXTree.string($0, kAXRoleAttribute) == "AXGroup"
        }
        guard project.index >= 0, project.index < groups.count else { return [] }
        let group = groups[project.index]
        // DSH 的「展开其余 N 个会话」是可点的按钮；展开后再读一次，避免只看到最近几条。
        let expanders = AXTree.all(in: group) { element in
            AXTree.string(element, kAXRoleAttribute) == "AXButton"
                && AXTree.string(element, kAXTitleAttribute).hasPrefix("展开其余")
        }
        for expander in expanders { _ = AXTree.press(expander) }
        if !expanders.isEmpty { try? await Task.sleep(for: .milliseconds(220)) }
        guard let refreshedWindow = focusedWindow(of: running),
              let refreshedOutline = deepSeekOutline(in: refreshedWindow) else { return [] }
        let refreshedGroups = AXTree.children(refreshedOutline).filter {
            AXTree.string($0, kAXRoleAttribute) == "AXGroup"
        }
        guard project.index < refreshedGroups.count else { return [] }
        let rows = deepSeekRows(in: refreshedGroups[project.index])
        guard let first = rows.first else { return [] }
        let projectName = deepSeekRowName(first)
        let title = AXTree.string(refreshedWindow, kAXTitleAttribute)
        return rows.dropFirst().enumerated().compactMap { index, row -> AgentSession? in
            let name = deepSeekRowName(row)
            guard !name.isEmpty, name != projectName else { return nil }
            return AgentSession(name: name, index: index,
                                isCurrent: AgentSessionNameMatcher.matches(windowTitle: title, sessionName: name))
        }
    }

    private static func openDeepSeek(project: AgentProject?, session: AgentSession,
                                     app: AgentSessionApp, running: NSRunningApplication) async -> Bool {
        guard let window = focusedWindow(of: running),
              let outline = deepSeekOutline(in: window) else { return false }
        let groups = AXTree.children(outline).filter {
            AXTree.string($0, kAXRoleAttribute) == "AXGroup"
        }
        let candidates: [AXUIElement]
        if let project {
            guard project.index >= 0, project.index < groups.count else { return false }
            candidates = Array(deepSeekRows(in: groups[project.index]).dropFirst())
        } else {
            // RECENT 是跨工作区拍平的会话列表；按名称优先、拍平下标兜底。
            candidates = groups.flatMap { group -> [AXUIElement] in
                let rows = deepSeekRows(in: group)
                guard let projectName = rows.first.map(deepSeekRowName) else { return [] }
                return rows.dropFirst().filter {
                    let name = deepSeekRowName($0)
                    return !name.isEmpty && name != projectName
                }
            }
        }
        let target = candidates.first(where: {
            deepSeekRowName($0) == session.name
        }) ?? candidates[safe: session.index]
        guard let target else { return false }
        return AXTree.press(target)
    }
}

/// 只读 AX 工具。所有函数都在主线程调用，不缓存元素。
@MainActor
private enum AXTree {
    static func value(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        (value(element, name) as? String) ?? ""
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        value(element, name) as? Bool
    }

    static func element(_ value: Any?) -> AXUIElement? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ value: Any?) -> [AXUIElement] {
        value as? [AXUIElement] ?? []
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(value(element, kAXChildrenAttribute))
    }

    static func hasAction(_ element: AXUIElement, _ action: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names = names as? [String] else { return false }
        return names.contains(action)
    }

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// 前序遍历，限制深度和节点数，避免 Electron 的巨大 AX 树拖住主线程。
    static func all(in root: AXUIElement, maxDepth: Int = 40, maxNodes: Int = 8_000,
                    where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var seen = Set<AXUIElement>()
        var result: [AXUIElement] = []
        while let (element, depth) = stack.popLast(), seen.count < maxNodes {
            guard seen.insert(element).inserted else { continue }
            if predicate(element) { result.append(element) }
            guard depth < maxDepth else { continue }
            for child in children(element).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
