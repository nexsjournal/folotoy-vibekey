import AppKit

/// 未登记 / 新出现的 Agent 走通用 AX 侧栏解析。
/// 只要窗口里有聊天输入框，并且左侧能读出项目或会话，就能在 Passport 上切换；
/// 读不到时返回 nil，不影响普通应用切换与听写。
@MainActor
struct GenericAgentSessionAdapter: AgentSessionAdapter {
    var bundleIDs: Set<String> { [] }

    func probeCatalog(for app: AgentSessionApp) async -> AgentCatalogProbe {
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid) else { return .notReady }
        let title = AgentAX.string(window, kAXTitleAttribute)
        let snapshot = AXSnapshot.capture(window: window)
        // 只有窗口边框时说明 Chromium 的 AX 树还没建好；内容已读全但没有聊天框则直接放弃。
        if snapshot.nodeCount < 80 { return .notReady }
        guard let parsed = AgentNavigationParser.parse(root: snapshot, windowTitle: title) else {
            return .notAgent
        }
        let catalog = makeCatalog(parsed, app: app)
        return catalog.isEmpty ? .notAgent : .found(catalog)
    }

    func loadSessions(for project: AgentProject, in app: AgentSessionApp) async -> [AgentSession] {
        if !project.sessions.isEmpty { return project.sessions }
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid) else { return [] }
        let snapshot = AXSnapshot.capture(window: window)
        guard let parsed = AgentNavigationParser.parse(
            root: snapshot, windowTitle: AgentAX.string(window, kAXTitleAttribute)),
              let target = parsed.projects.first(where: { $0.name == project.name }) else {
            return []
        }
        // 折叠项目先展开：优先按 Claude 的 "Toggle sessions for"，否则按项目标题按钮。
        guard let header = AgentAX.element(at: target.path, in: window),
              subtreeText(header).contains(project.name),
              let toggle = toggleButton(in: header, project: project.name) else {
            return sessions(target, app: app)
        }
        guard AgentAX.press(toggle) else { return [] }
        try? await Task.sleep(for: .milliseconds(350))
        guard let refreshed = AgentSessionCatalogLoader.focusedWindow(of: app.pid) else { return [] }
        let updated = AXSnapshot.capture(window: refreshed)
        guard let reparsed = AgentNavigationParser.parse(
            root: updated, windowTitle: AgentAX.string(refreshed, kAXTitleAttribute)),
              let match = reparsed.projects.first(where: { $0.name == project.name }) else {
            return []
        }
        return sessions(match, app: app)
    }

    func open(project: AgentProject?, session: AgentSession, in app: AgentSessionApp) async -> Bool {
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid) else { return false }
        let snapshot = AXSnapshot.capture(window: window)
        guard let parsed = AgentNavigationParser.parse(
            root: snapshot, windowTitle: AgentAX.string(window, kAXTitleAttribute)) else {
            return false
        }
        let candidates: [ParsedAgentSession]
        if let project {
            guard let match = parsed.projects.first(where: { $0.name == project.name }) else { return false }
            candidates = match.sessions
        } else {
            candidates = parsed.recent
        }
        let target = candidates.first(where: { $0.index == session.index && $0.name == session.name })
            ?? candidates.first(where: { $0.name == session.name })
            ?? candidates[safe: session.index]
        guard let target,
              let row = AgentAX.element(at: target.path, in: window),
              subtreeText(row).contains(target.name),
              let pressable = AgentAX.firstPressable(in: row) else { return false }
        return AgentAX.press(pressable)
    }

    private func makeCatalog(_ parsed: ParsedAgentNavigation, app: AgentSessionApp) -> AgentSessionCatalog {
        let projects = parsed.projects.enumerated().map { index, project in
            AgentProject(
                name: project.name, index: index,
                sessions: sessions(project, app: app),
                isCurrent: project.isCurrent || project.sessions.contains(where: \.isCurrent))
        }
        var recent = parsed.recent.map {
            AgentSession(name: $0.name, index: $0.index, isCurrent: $0.isCurrent)
        }
        if recent.isEmpty {
            recent = Array(projects.flatMap(\.sessions).prefix(20))
        }
        return AgentSessionCatalog(app: app, projects: projects, recent: recent)
    }

    private func sessions(_ project: ParsedAgentProject, app: AgentSessionApp) -> [AgentSession] {
        project.sessions.map {
            AgentSession(name: $0.name, index: $0.index, isCurrent: $0.isCurrent)
        }
    }

    /// 优先找 Claude 的折叠开关；否则用标题按钮本身。
    private func toggleButton(in header: AXUIElement, project: String) -> AXUIElement? {
        let buttons = AgentAX.all(in: header, maxDepth: 4) {
            AgentAX.hasAction($0, kAXPressAction as String)
        }
        if let toggle = buttons.first(where: { element in
            let text = (AgentAX.string(element, kAXTitleAttribute) + " "
                + AgentAX.string(element, kAXDescriptionAttribute)).lowercased()
            return text.contains("toggle sessions") || text.hasPrefix("展开") || text.hasPrefix("收起")
        }) {
            return toggle
        }
        return buttons.first {
            AgentAX.string($0, kAXTitleAttribute) == project
                || AgentAX.string($0, kAXDescriptionAttribute) == project
        } ?? buttons.first
    }

    /// 路径来自快照下标；按下前核对子树里确实有目标名字，
    /// 避免 Chrome 节点复用 / 树刷新时按到关闭按钮。
    private func subtreeText(_ element: AXUIElement) -> String {
        var parts: [String] = []
        for node in AgentAX.all(in: element, maxDepth: 5, where: { _ in true }) {
            parts.append(AgentAX.string(node, kAXTitleAttribute))
            parts.append(AgentAX.string(node, kAXDescriptionAttribute))
            if AgentAX.string(node, kAXRoleAttribute) == "AXStaticText" {
                parts.append(AgentAX.string(node, kAXValueAttribute))
            }
        }
        return parts.joined(separator: "\n")
    }
}
