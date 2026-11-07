import AppKit

/// DeepSeek Honeycomb 的侧栏是 AXOutline：每个项目一个 AXGroup，
/// 第一行是项目名，后续行是会话。行本身通常没有再嵌套的按钮，需要直接按行。
@MainActor
struct DeepSeekAgentSessionAdapter: AgentSessionAdapter {
    static let bundleID = "ai.deepseek.dsh.desktop.next"
    var bundleIDs: Set<String> { [Self.bundleID] }

    func probeCatalog(for app: AgentSessionApp) async -> AgentCatalogProbe {
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid) else { return .notReady }
        let title = AgentAX.string(window, kAXTitleAttribute)
        guard let outline = outline(in: window) else { return .notReady }
        let groups = AgentAX.children(outline).filter {
            AgentAX.string($0, kAXRoleAttribute) == "AXGroup"
        }
        let projects = groups.enumerated().compactMap { index, group -> AgentProject? in
            let rows = rows(in: group)
            guard let first = rows.first else { return nil }
            let projectName = rowName(first)
            guard !projectName.isEmpty else { return nil }
            let sessions = rows.dropFirst().enumerated().compactMap { index, row -> AgentSession? in
                let name = rowName(row)
                guard !name.isEmpty, name != projectName else { return nil }
                return AgentSession(name: name, index: index,
                                    isCurrent: AgentSessionNameMatcher.matches(
                                        windowTitle: title, sessionName: name))
            }
            return AgentProject(name: projectName, index: index, sessions: sessions,
                                isCurrent: sessions.contains(where: \.isCurrent))
        }
        return .found(AgentSessionCatalog(
            app: app, projects: projects,
            recent: Array(projects.flatMap(\.sessions).prefix(20))))
    }

    func loadSessions(for project: AgentProject, in app: AgentSessionApp) async -> [AgentSession] {
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid),
              let navOutline = outline(in: window) else { return [] }
        let groups = AgentAX.children(navOutline).filter {
            AgentAX.string($0, kAXRoleAttribute) == "AXGroup"
        }
        guard project.index >= 0, project.index < groups.count else { return [] }
        let group = groups[project.index]
        // 「展开其余 N 个会话」是可点的按钮；展开后再读一次，避免只看到最近几条。
        let expanders = AgentAX.all(in: group) { element in
            AgentAX.string(element, kAXRoleAttribute) == "AXButton"
                && AgentAX.string(element, kAXTitleAttribute).hasPrefix("展开其余")
        }
        for expander in expanders { _ = AgentAX.press(expander) }
        if !expanders.isEmpty { try? await Task.sleep(for: .milliseconds(220)) }
        guard let refreshedWindow = AgentSessionCatalogLoader.focusedWindow(of: app.pid),
              let refreshedOutline = outline(in: refreshedWindow) else { return [] }
        let refreshedGroups = AgentAX.children(refreshedOutline).filter {
            AgentAX.string($0, kAXRoleAttribute) == "AXGroup"
        }
        guard project.index < refreshedGroups.count else { return [] }
        let projectRows = rows(in: refreshedGroups[project.index])
        guard let first = projectRows.first else { return [] }
        let projectName = rowName(first)
        let title = AgentAX.string(refreshedWindow, kAXTitleAttribute)
        return projectRows.dropFirst().enumerated().compactMap { index, row -> AgentSession? in
            let name = rowName(row)
            guard !name.isEmpty, name != projectName else { return nil }
            return AgentSession(name: name, index: index,
                                isCurrent: AgentSessionNameMatcher.matches(
                                    windowTitle: title, sessionName: name))
        }
    }

    func open(project: AgentProject?, session: AgentSession, in app: AgentSessionApp) async -> Bool {
        guard let window = AgentSessionCatalogLoader.focusedWindow(of: app.pid),
              let outline = outline(in: window) else { return false }
        let groups = AgentAX.children(outline).filter {
            AgentAX.string($0, kAXRoleAttribute) == "AXGroup"
        }
        let candidates: [AXUIElement]
        if let project {
            guard project.index >= 0, project.index < groups.count else { return false }
            candidates = Array(rows(in: groups[project.index]).dropFirst())
        } else {
            // RECENT 是跨工作区拍平的会话列表；按名称优先、拍平下标兜底。
            candidates = groups.flatMap { group -> [AXUIElement] in
                let rows = rows(in: group)
                guard let projectName = rows.first.map(rowName) else { return [] }
                return rows.dropFirst().filter {
                    let name = rowName($0)
                    return !name.isEmpty && name != projectName
                }
            }
        }
        let target = candidates.first(where: { rowName($0) == session.name })
            ?? candidates[safe: session.index]
        guard let target else { return false }
        return AgentAX.press(target)
    }

    // MARK: - AX

    private func outline(in window: AXUIElement) -> AXUIElement? {
        let outlines = AgentAX.all(in: window) { AgentAX.string($0, kAXRoleAttribute) == "AXOutline" }
        return outlines.first { AgentAX.string($0, kAXDescriptionAttribute) == "会话" }
            ?? outlines.first { !rows(in: $0).isEmpty }
    }

    private func rows(in element: AXUIElement) -> [AXUIElement] {
        AgentAX.all(in: element) { AgentAX.string($0, kAXRoleAttribute) == "AXRow" }
    }

    private func rowName(_ row: AXUIElement) -> String {
        let texts = AgentAX.all(in: row) { element in
            AgentAX.string(element, kAXRoleAttribute) == "AXStaticText"
        }.map { AgentAX.string($0, kAXValueAttribute) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isStatusOrRelativeTime($0) }
        if let longest = texts.max(by: { $0.count < $1.count }) { return longest }
        return AgentAX.string(row, kAXTitleAttribute)
    }

    private func isStatusOrRelativeTime(_ text: String) -> Bool {
        if ["进行中", "已完成", "等待输入", "等待中", "失败", "刚刚"].contains(text) { return true }
        return text.range(of: #"^\d+\s*(秒|分钟|分|小时|天|周|个月|月|年)$"#, options: .regularExpression) != nil
    }
}
