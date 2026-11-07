import AppKit

/// Codex 的项目分组没有标准 AXOutline：每个项目是一个 title == description 的 AXGroup，
/// 组内既有项目按钮，也有会话按钮。这里保留专门解析，稳过通用启发式。
@MainActor
struct CodexAgentSessionAdapter: AgentSessionAdapter {
    var bundleIDs: Set<String> { [AccessibilityCodexDesktopAdapter.bundleIdentifier] }

    func probeCatalog(for app: AgentSessionApp) async -> AgentCatalogProbe {
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid) else { return .notReady }
        let title = AgentAX.string(window, kAXTitleAttribute)
        let groups = projectGroups(in: window)
        guard !groups.isEmpty else { return .notReady }
        let projects = groups.enumerated().map { index, group in
            let name = AgentAX.string(group, kAXTitleAttribute)
            let sessions = sessionButtons(in: group, projectName: name).enumerated().map { offset, button in
                let sessionName = AgentAX.string(button, kAXTitleAttribute)
                return AgentSession(name: sessionName, index: offset,
                                    isCurrent: AgentSessionNameMatcher.matches(
                                        windowTitle: title, sessionName: sessionName))
            }
            return AgentProject(name: name, index: index, sessions: sessions,
                                isCurrent: sessions.contains(where: \.isCurrent))
        }
        return .found(AgentSessionCatalog(
            app: app, projects: projects,
            recent: recentSessions(in: window, windowTitle: title)))
    }

    func loadSessions(for project: AgentProject, in app: AgentSessionApp) async -> [AgentSession] {
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid) else { return [] }
        guard let group = projectGroup(in: window, index: project.index, name: project.name),
              let button = projectButton(in: group) else { return [] }
        if AgentAX.bool(button, "AXExpanded") != true {
            _ = AgentAX.press(button)
            try? await Task.sleep(for: .milliseconds(220))
        }
        guard let refreshedWindow = AgentSessionCatalogLoader.focusedWindow(of: app.pid),
              let refreshed = projectGroup(in: refreshedWindow, index: project.index, name: project.name) else {
            return []
        }
        let name = AgentAX.string(refreshed, kAXTitleAttribute)
        let title = AgentAX.string(refreshedWindow, kAXTitleAttribute)
        let sessions = sessionButtons(in: refreshed, projectName: name).enumerated().map { index, element in
            let sessionName = AgentAX.string(element, kAXTitleAttribute)
            return AgentSession(name: sessionName, index: index,
                                isCurrent: AgentSessionNameMatcher.matches(
                                    windowTitle: title, sessionName: sessionName))
        }
        if sessions.isEmpty, startNewChatButton(in: refreshed, projectName: name) != nil {
            return [AgentSession(name: "NEW CHAT", index: AgentSession.newChatIndex, isCurrent: false)]
        }
        return sessions
    }

    func open(project: AgentProject?, session: AgentSession, in app: AgentSessionApp) async -> Bool {
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid) else { return false }
        if let project {
            guard var group = projectGroup(in: window, index: project.index, name: project.name),
                  let button = projectButton(in: group) else { return false }
            if AgentAX.bool(button, "AXExpanded") != true {
                _ = AgentAX.press(button)
                try? await Task.sleep(for: .milliseconds(220))
                guard let refreshedWindow = AgentSessionCatalogLoader.focusedWindow(of: app.pid),
                      let refreshed = projectGroup(
                        in: refreshedWindow, index: project.index, name: project.name) else {
                    return false
                }
                group = refreshed
            }
            let projectName = AgentAX.string(group, kAXTitleAttribute)
            if session.index == AgentSession.newChatIndex {
                guard let newChat = startNewChatButton(in: group, projectName: projectName) else {
                    return false
                }
                return AgentAX.press(newChat)
            }
            let buttons = sessionButtons(in: group, projectName: projectName)
            let target = buttons.enumerated().first {
                $0.offset == session.index && AgentAX.string($0.element, kAXTitleAttribute) == session.name
            }?.element ?? buttons.first { AgentAX.string($0, kAXTitleAttribute) == session.name }
            guard let target else { return false }
            return AgentAX.press(target)
        }
        // 最近列表：只在最近列表的按钮中找，避免同名项目会话误触。
        let recent = recentSessions(in: window, windowTitle: AgentAX.string(window, kAXTitleAttribute))
        guard let match = recent.first(where: { $0.index == session.index && $0.name == session.name })
                ?? recent.first(where: { $0.name == session.name }) else { return false }
        let buttons = recentButtons(in: window)
        let target = buttons[safe: match.index].flatMap {
            AgentAX.string($0, kAXTitleAttribute) == match.name ? $0 : nil
        } ?? buttons.first(where: { AgentAX.string($0, kAXTitleAttribute) == match.name })
        guard let target else { return false }
        return AgentAX.press(target)
    }

    // MARK: - AX

    private func projectGroups(in window: AXUIElement) -> [AXUIElement] {
        AgentAX.all(in: window) { element in
            guard AgentAX.string(element, kAXRoleAttribute) == "AXGroup" else { return false }
            let title = AgentAX.string(element, kAXTitleAttribute)
            guard !title.isEmpty, title == AgentAX.string(element, kAXDescriptionAttribute) else {
                return false
            }
            return !AgentAX.all(in: element, maxDepth: 3) { child in
                AgentAX.string(child, kAXRoleAttribute) == "AXButton"
                    && AgentAX.string(child, kAXTitleAttribute) == title
            }.isEmpty
        }
    }

    private func projectGroup(in window: AXUIElement, index: Int, name: String?) -> AXUIElement? {
        let groups = projectGroups(in: window)
        guard index >= 0, index < groups.count else { return nil }
        let group = groups[index]
        if let name, AgentAX.string(group, kAXTitleAttribute) != name { return nil }
        return group
    }

    private func projectButton(in group: AXUIElement) -> AXUIElement? {
        let name = AgentAX.string(group, kAXTitleAttribute)
        return AgentAX.all(in: group, maxDepth: 4) { element in
            AgentAX.string(element, kAXRoleAttribute) == "AXButton"
                && AgentAX.string(element, kAXTitleAttribute) == name
        }.first
    }

    private func startNewChatButton(in group: AXUIElement, projectName: String) -> AXUIElement? {
        AgentAX.all(in: group) { element in
            AgentAX.string(element, kAXRoleAttribute) == "AXButton"
                && AgentAX.string(element, kAXTitleAttribute) == "在 \(projectName) 中开始新聊天"
        }.first
    }

    private func sessionButtons(in group: AXUIElement, projectName: String) -> [AXUIElement] {
        AgentAX.all(in: group) { element in
            guard AgentAX.string(element, kAXRoleAttribute) == "AXButton" else { return false }
            let title = AgentAX.string(element, kAXTitleAttribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != projectName else { return false }
            let excluded = ["置顶聊天", "归档聊天", "项目操作", "展开其余", "新聊天"]
            guard !excluded.contains(title) else { return false }
            if title.hasPrefix("在 ") && title.contains("中开始新聊天") { return false }
            return AgentAX.hasAction(element, kAXPressAction as String)
        }
    }

    private func recentSessions(in window: AXUIElement, windowTitle: String) -> [AgentSession] {
        let buttons = recentButtons(in: window)
        return buttons.enumerated().map { index, button in
            let name = AgentAX.string(button, kAXTitleAttribute)
            return AgentSession(name: name, index: index,
                                isCurrent: AgentSessionNameMatcher.matches(
                                    windowTitle: windowTitle, sessionName: name))
        }
    }

    private func recentButtons(in window: AXUIElement) -> [AXUIElement] {
        let recentButtons = AgentAX.all(in: window, where: { element in
            AgentAX.string(element, kAXRoleAttribute) == "AXButton"
                && ["最近", "Recent"].contains(AgentAX.string(element, kAXTitleAttribute))
        })
        guard let recent = recentButtons.first else { return [] }
        // 从「最近」按钮往上找最近的、包含会话按钮的 group；避免把整个侧栏的按钮都算进来。
        var node: AXUIElement? = recent
        while let current = node {
            let buttons = AgentAX.all(in: current) { element in
                guard AgentAX.string(element, kAXRoleAttribute) == "AXButton" else { return false }
                let title = AgentAX.string(element, kAXTitleAttribute)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty,
                      !["新聊天", "聊天侧边栏选项", "置顶聊天", "归档聊天", "最近", "Recent"].contains(title) else {
                    return false
                }
                return AgentAX.hasAction(element, kAXPressAction as String)
            }
            if !buttons.isEmpty { return buttons }
            node = AgentAX.element(AgentAX.value(current, kAXParentAttribute))
        }
        return []
    }
}
