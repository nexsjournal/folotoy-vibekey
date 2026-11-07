import Foundation

/// 通用 AX 侧栏解析结果。路径是从窗口根节点开始的子节点下标，操作前重新读取窗口再按路径定位。
nonisolated struct ParsedAgentSession: Equatable, Sendable {
    let name: String
    let index: Int
    let isCurrent: Bool
    let path: [Int]
}

nonisolated struct ParsedAgentProject: Equatable, Sendable {
    let name: String
    let index: Int
    let isCurrent: Bool
    let path: [Int]
    let sessions: [ParsedAgentSession]
}

nonisolated struct ParsedAgentNavigation: Equatable, Sendable {
    let projects: [ParsedAgentProject]
    let recent: [ParsedAgentSession]
    let composerPath: [Int]
    let composerRect: AXSnapshotNode.Rect

    var isEmpty: Bool { projects.allSatisfy(\.sessions.isEmpty) && recent.isEmpty }
}

/// 不依赖具体 App 的侧栏启发式：
/// 1. 先确认窗口里有聊天输入框（AXTextArea，或占位文字像聊天框的 AXTextField）；
/// 2. 在侧栏 landmark / AXOutline 里按文档顺序找“项目标题”和“会话行”；
/// 3. 会话行必须是可点击、在输入框左侧（或位于 landmark 内）、且位于列表 / 带相对时间的行里。
///
/// 这样 Codex、DSH、ZCode、Claude、WorkBuddy 以及未登记的新 Agent 都能走同一条路径；
/// 找不到侧栏时返回 nil，调用方回退为普通应用切换，不会把普通文档窗口误当成会话列表。
nonisolated enum AgentNavigationParser {
    private static let chromeNames: Set<String> = [
        "新建", "新建任务", "新任务", "新聊天", "新建聊天", "新项目", "新建项目",
        "项目", "projects", "project", "任务列表", "任务", "空间",
        "搜索", "搜索…", "搜索...", "search", "search…", "filter", "筛选", "筛选视图",
        "设置", "settings", "偏好设置", "preferences",
        "发送", "send", "停止", "stop", "取消", "cancel", "重试", "retry",
        "最近", "recent", "置顶", "pinned", "归档", "archive", "已归档", "archived",
        "更多", "more", "更多操作", "more options", "操作", "options",
        "收起", "展开", "收起侧边栏", "展开侧边栏", "hide sidebar", "show sidebar",
        "返回", "back", "关闭", "close", "删除", "delete", "重命名", "rename",
        "分享", "share", "复制", "copy", "帮助", "help", "升级", "upgrade",
        "助理", "assistant", "专家·技能·连接器", "技能", "资料库", "定时任务",
        "cowork", "code", "chat", "work", "agent", "agents", "发现应用",
        "自动化", "插件市场", "命令面板", "隐藏侧边栏", "显示侧边栏",
    ]

    private static let chromePrefixes = [
        "toggle sessions for ", "mark as unread ", "mark as read ", "hide ", "show ",
    ]

    /// 只剥掉这些“标签前缀”，不能把「创建…」「新建…」开头的会话标题也截掉。
    private static let labelPrefixes = [
        "toggle sessions for ", "mark as unread ", "mark as read ", "unread ", "未读 ",
    ]

    private static let timePatterns = [
        #"^\d+\s*(秒|分钟|分|小时|天|周|个月|月|年)前$"#,
        #"^(刚刚|刚才|今天|昨天|前天)$"#,
        #"^\d{1,2}\s*月\s*\d{1,2}\s*日$"#,
        #"^\d{4}[-/]\d{1,2}[-/]\d{1,2}$"#,
        #"^\d{1,2}:\d{2}$"#,
        #"^(\d+\s*(s|m|h|d|w|mo|y)\s*ago|just now|yesterday|today)$"#,
        #"^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2}$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let statusNames: Set<String> = [
        "进行中", "已完成", "等待输入", "等待中", "失败", "待处理", "未读",
        "running", "done", "failed", "waiting", "pending", "unread",
    ]

    static func parse(root: AXSnapshotNode, windowTitle: String) -> ParsedAgentNavigation? {
        guard let composer = findComposer(root) else { return nil }
        let landmarks = findLandmarks(root)
        let roots = landmarks.isEmpty ? [([], root)] : landmarks
        var collector = Collector(windowTitle: windowTitle,
                                  contextTitles: [windowTitle] + headingTitles(root),
                                  composerPath: composer.path,
                                  composerRect: composer.rect, hasLandmarks: !landmarks.isEmpty)
        for (path, node) in roots {
            collector.scan(node, path: path, inList: false)
        }
        return collector.finish()
    }

    // MARK: - 输入框

    struct Composer {
        let path: [Int]
        let rect: AXSnapshotNode.Rect
    }

    static func findComposer(_ root: AXSnapshotNode) -> Composer? {
        var best: (path: [Int], rect: AXSnapshotNode.Rect, score: Double)?
        func walk(_ node: AXSnapshotNode, _ path: [Int]) {
            if node.enabled, !isSearchField(node), let rect = composerRect(node) {
                let score = rect.area + (node.role == "AXTextArea" ? 10_000 : 0)
                if best == nil || score > best!.score {
                    best = (path, rect, score)
                }
            }
            for (index, child) in node.children.enumerated() {
                walk(child, path + [index])
            }
        }
        walk(root, [])
        return best.map { .init(path: $0.path, rect: $0.rect) }
    }

    private static func composerRect(_ node: AXSnapshotNode) -> AXSnapshotNode.Rect? {
        switch node.role {
        case "AXTextArea":
            guard node.rect.height >= 20 else { return nil }
            return node.rect
        case "AXTextField":
            guard hasChatPlaceholder(node) else { return nil }
            return node.rect
        default:
            return nil
        }
    }

    private static func hasChatPlaceholder(_ node: AXSnapshotNode) -> Bool {
        let text = (node.placeholder + " " + node.description + " " + node.title).lowercased()
        let hints = ["消息", "发消息", "输入", "提问", "回复", "message", "ask", "prompt", "reply", "type"]
        return hints.contains { text.contains($0) }
    }

    private static func isSearchField(_ node: AXSnapshotNode) -> Bool {
        if node.subrole == "AXSearchField" { return true }
        let text = (node.placeholder + " " + node.description + " " + node.title).lowercased()
        let hints = ["搜索", "筛选", "search", "filter", "rename", "重命名"]
        return hints.contains { text.contains($0) }
    }

    /// 主内容区的 AXHeading 常常就是当前打开的会话标题（ZCode / Claude），
    /// 侧栏行本身没有 AXSelected 时用它补 `*` 标记。
    private static func headingTitles(_ root: AXSnapshotNode) -> [String] {
        var titles: [String] = []
        func walk(_ node: AXSnapshotNode) {
            if node.role == "AXHeading" {
                var text = node.value.isEmpty ? node.title : node.value
                if text.isEmpty { text = displayName(node, titleFirst: false) }
                let name = cleanName(text)
                if !name.isEmpty { titles.append(name) }
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        return Array(titles.prefix(20))
    }

    // MARK: - 侧栏范围

    static func findLandmarks(_ root: AXSnapshotNode) -> [([Int], AXSnapshotNode)] {
        var result: [([Int], AXSnapshotNode)] = []
        func walk(_ node: AXSnapshotNode, _ path: [Int]) {
            if isLandmark(node), containsPressable(node) {
                result.append((path, node))
                return
            }
            for (index, child) in node.children.enumerated() {
                walk(child, path + [index])
            }
        }
        walk(root, [])
        return result
    }

    private static func isLandmark(_ node: AXSnapshotNode) -> Bool {
        // landmark 必须是容器；侧栏折叠时只剩一个「侧边栏」按钮，不能把它当导航区。
        guard !node.children.isEmpty,
              !["AXButton", "AXLink", "AXRadioButton"].contains(node.role),
              node.rect.isEmpty || node.rect.height > 40 else { return false }
        if node.subrole.contains("AXLandmarkNavigation") || node.subrole.contains("AXLandmarkComplementary") {
            return true
        }
        let text = (node.description + " " + node.title).lowercased()
        return text.contains("sidebar") || text.contains("侧边栏") || text == "会话"
    }

    private static func containsPressable(_ node: AXSnapshotNode) -> Bool {
        if node.isPressable { return true }
        return node.children.contains(where: containsPressable)
    }

    // MARK: - 扫描

    private struct Collector {
        let windowTitle: String
        let contextTitles: [String]
        let composerPath: [Int]
        let composerRect: AXSnapshotNode.Rect
        let hasLandmarks: Bool
        /// 排查未登记 Agent 时设 IB_NAV_TRACE=1，打印每层判定；正常运行时没有额外开销。
        private let trace = ProcessInfo.processInfo.environment["IB_NAV_TRACE"] != nil
        private var currentProject: String?
        private var headers: [(name: String, path: [Int], selected: Bool)] = []
        private var sessions: [(session: ParsedAgentSession, project: String?)] = []

        init(windowTitle: String, contextTitles: [String], composerPath: [Int], composerRect: AXSnapshotNode.Rect,
             hasLandmarks: Bool) {
            self.windowTitle = windowTitle
            self.contextTitles = contextTitles
            self.composerPath = composerPath
            self.composerRect = composerRect
            self.hasLandmarks = hasLandmarks
        }

        mutating func scan(_ node: AXSnapshotNode, path: [Int], inList: Bool) {
            if trace, path.count < 30, !node.rect.isEmpty, node.rect.height <= 200,
               inList || node.isPressable || node.role == "AXStaticText" {
                let name = AgentNavigationParser.displayName(node, titleFirst: false)
                print("[NAV] \(String(repeating: "  ", count: path.count))\(node.role) "
                    + "h=\(Int(node.rect.height)) x=\(Int(node.rect.x)) list=\(inList) \(name)")
            }
            if !path.isEmpty, isHeader(node, inList: inList) {
                let name = AgentNavigationParser.displayName(node, titleFirst: false)
                if trace { print("[NAV] HEADER \(node.role) h=\(Int(node.rect.height)) \(name)") }
                if !name.isEmpty {
                    currentProject = name
                    if !headers.contains(where: { $0.name == name }) {
                        headers.append((name, path, node.selected || hasSelected(node)))
                    }
                }
                return
            }
            if isSession(node, path: path, inList: inList) {
                let name = AgentNavigationParser.displayName(node, titleFirst: false)
                if trace { print("[NAV] SESSION \(node.role) h=\(Int(node.rect.height)) \(name)") }
                if !name.isEmpty {
                    let current = node.selected || hasSelected(node)
                        || contextTitles.contains {
                            AgentSessionNameMatcher.matches(windowTitle: $0, sessionName: name)
                        }
                    sessions.append((ParsedAgentSession(
                        name: name, index: 0, isCurrent: current, path: path), currentProject))
                }
                return
            }
            let childInList = node.role == "AXList" || node.role == "AXOutline" || node.subrole == "AXContentList"
            for (index, child) in node.children.enumerated() {
                scan(child, path: path + [index], inList: childInList)
            }
        }

        func finish() -> ParsedAgentNavigation? {
            var projects: [ParsedAgentProject] = []
            var indexByName: [String: Int] = [:]
            var recent: [ParsedAgentSession] = []

            for header in headers {
                guard indexByName[header.name] == nil else { continue }
                indexByName[header.name] = projects.count
                projects.append(ParsedAgentProject(
                    name: header.name, index: projects.count, isCurrent: header.selected,
                    path: header.path, sessions: []))
            }

            for entry in sessions {
                if let project = entry.project, let index = indexByName[project] {
                    let existing = projects[index]
                    let session = ParsedAgentSession(
                        name: entry.session.name, index: existing.sessions.count,
                        isCurrent: entry.session.isCurrent, path: entry.session.path)
                    projects[index] = ParsedAgentProject(
                        name: existing.name, index: existing.index,
                        isCurrent: existing.isCurrent || session.isCurrent,
                        path: existing.path, sessions: existing.sessions + [session])
                } else {
                    recent.append(entry.session)
                }
            }

            let cleanedRecent = recent.enumerated().map { offset, session in
                ParsedAgentSession(name: session.name, index: offset,
                                   isCurrent: session.isCurrent, path: session.path)
            }
            // 侧栏顶部的 App 名 / Logo 链接会被读成项目；没有会话且名字等于窗口标题时去掉。
            projects.removeAll {
                $0.sessions.isEmpty
                    && $0.name.caseInsensitiveCompare(AgentSessionNameMatcher.normalizedWindowTitle(windowTitle)) == .orderedSame
            }
            let reindexed = projects.enumerated().map { index, project in
                ParsedAgentProject(name: project.name, index: index, isCurrent: project.isCurrent,
                                   path: project.path, sessions: project.sessions)
            }
            guard !reindexed.isEmpty || !cleanedRecent.isEmpty else { return nil }
            return ParsedAgentNavigation(
                projects: reindexed, recent: Array(cleanedRecent.prefix(20)),
                composerPath: composerPath, composerRect: composerRect)
        }

        // MARK: 判断

        private func isHeader(_ node: AXSnapshotNode, inList: Bool) -> Bool {
            guard ["AXGroup", "AXRow", "AXListItem", "AXCell"].contains(node.role) else { return false }
            // 列表里的行永远是会话；项目标题在列表外。
            guard !inList else { return false }
            guard !node.rect.isEmpty ? node.rect.height <= 56 : true else { return false }
            let name = AgentNavigationParser.displayName(node, titleFirst: false)
            guard !name.isEmpty, !AgentNavigationParser.isChrome(name) else { return false }
            if containsListWithRows(node) { return false }

            // 标题按钮：项目名本身就是按钮（ZCode / Claude / Codex 的项目分组）。
            if containsPressable(named: name, in: node) { return true }
            // 折叠开关：Claude 的 "Toggle sessions for <project>"。
            if containsPressableToggle(in: node, project: name) { return true }
            // 纯文字分组头（WorkBuddy 的空间名）：自身可能可点，但没有带名字的按钮。
            if !hasNamedPressable(node), singleTextCount(node) == 1 { return true }
            return false
        }

        private func isSession(_ node: AXSnapshotNode, path: [Int], inList: Bool) -> Bool {
            guard node.enabled, !node.rect.isEmpty ? node.rect.height <= 180 : true else { return false }
            guard !AgentNavigationParser.isPath(path, prefixOf: composerPath) else { return false }
            guard node.isPressable || node.children.contains(where: AgentNavigationParser.containsPressable) else {
                return false
            }
            let name = AgentNavigationParser.displayName(node, titleFirst: false)
            guard !name.isEmpty, name.count <= 200, !AgentNavigationParser.isChrome(name) else { return false }
            guard !looksLikeReplyOrToolbar(node) else { return false }
            let timed = AgentNavigationParser.hasTimeText(node)
            guard inList || timed || node.role == "AXRow" else { return false }
            if !hasLandmarks, !node.rect.isEmpty, !composerRect.isEmpty {
                guard node.rect.maxX <= composerRect.midX, node.rect.x < composerRect.x else {
                    return false
                }
            }
            return true
        }

        private func looksLikeReplyOrToolbar(_ node: AXSnapshotNode) -> Bool {
            let text = AgentNavigationParser.displayName(node, titleFirst: false).lowercased()
            return text.hasPrefix("mark as unread") || text.hasPrefix("mark as read")
                || text.hasPrefix("toggle sessions for")
        }

        private func containsListWithRows(_ node: AXSnapshotNode) -> Bool {
            for child in node.children {
                if child.role == "AXList" || child.role == "AXOutline" || child.subrole == "AXContentList" {
                    if !child.children.isEmpty { return true }
                }
                if containsListWithRows(child) { return true }
            }
            return false
        }

        private func containsPressable(named name: String, in node: AXSnapshotNode) -> Bool {
            if node.isPressable {
                // 不能用 cleanName：它会剥掉 "Mark as unread" / "Toggle sessions" 前缀，
                // 让 Claude 的会话行被误判成项目标题。这里只比较原始标题。
                let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let description = node.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if title == name || description == name { return true }
            }
            return node.children.contains { containsPressable(named: name, in: $0) }
        }

        private func hasNamedPressable(_ node: AXSnapshotNode) -> Bool {
            if node.isPressable,
               (!node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !node.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                return true
            }
            return node.children.contains(where: hasNamedPressable)
        }

        private func containsPressableToggle(in node: AXSnapshotNode, project: String) -> Bool {
            if node.isPressable {
                let text = (node.title + " " + node.description).lowercased()
                if text.hasPrefix("toggle sessions for "), text.contains(project.lowercased()) {
                    return true
                }
                if (text.hasPrefix("展开") || text.hasPrefix("收起") || text.contains("expand") || text.contains("collapse")),
                   text.contains(project.lowercased()) {
                    return true
                }
            }
            return node.children.contains { containsPressableToggle(in: $0, project: project) }
        }

        private func singleTextCount(_ node: AXSnapshotNode) -> Int {
            var count = 0
            func walk(_ node: AXSnapshotNode) {
                if node.role == "AXStaticText" { count += 1 }
                for child in node.children { walk(child) }
            }
            walk(node)
            return count
        }

        private func hasSelected(_ node: AXSnapshotNode) -> Bool {
            if node.selected || node.ariaCurrent { return true }
            return node.children.contains(where: hasSelected)
        }
    }

    // MARK: - 文本

    static func displayName(_ node: AXSnapshotNode, titleFirst: Bool) -> String {
        if titleFirst, let name = firstNonEmpty([node.title, node.description, node.value]) {
            return cleanName(name)
        }
        var texts: [String] = []
        func collect(_ node: AXSnapshotNode) {
            if node.role == "AXStaticText" {
                let value = node.value.isEmpty ? node.title : node.value
                if !value.isEmpty { texts.append(value) }
            }
            for child in node.children { collect(child) }
        }
        collect(node)
        if let name = texts
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty && !isNoise($0) })
            .max(by: { $0.count < $1.count }) {
            return cleanName(name)
        }
        var pressableTexts: [String] = []
        func collectPressable(_ node: AXSnapshotNode) {
            if node.isPressable {
                pressableTexts.append(node.title)
                pressableTexts.append(node.description)
            }
            for child in node.children { collectPressable(child) }
        }
        collectPressable(node)
        if let name = pressableTexts
            .map(cleanName)
            .filter({ !$0.isEmpty && !isNoise($0) && !isChrome($0) })
            .max(by: { $0.count < $1.count }) {
            return name
        }
        return cleanName(firstNonEmpty([node.title, node.description, node.value]) ?? "")
    }

    private static func firstNonEmpty(_ values: [String]) -> String? {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = name.lowercased()
        for prefix in labelPrefixes where lowered.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        // WorkBuddy 把相对时间拼在按钮标题里，例如 "创建动画 3天前"。
        name = name.replacingOccurrences(
            of: #"\s+\d+\s*(秒|分钟|分|小时|天|周|个月|月|年)前$"#,
            with: "", options: .regularExpression)
        name = name.replacingOccurrences(
            of: #"\s+(\d+\s*(s|m|h|d|w|mo|y)\s*ago|just now|yesterday|today)$"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        name = name.replacingOccurrences(
            of: #"\s+\d{1,2}\s*月\s*\d{1,2}\s*日$"#,
            with: "", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNoise(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        if statusNames.contains(value.lowercased()) { return true }
        return timePatterns.contains { pattern in
            pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
    }

    static func isChrome(_ name: String) -> Bool {
        let value = cleanName(name).lowercased()
        if value.isEmpty { return true }
        if chromeNames.contains(value) { return true }
        if chromePrefixes.contains(where: { value.hasPrefix($0) }) { return true }
        // "在 <项目> 中开始新聊天" 是 Codex 的建聊按钮，项目名本身可能很长。
        if value.hasPrefix("在 ") && value.hasSuffix("中开始新聊天") { return true }
        // "任务 (43)" / "空间 (32)" / "V5.9.3" 这类计数与版本号。
        if value.range(of: #"^[\p{Han}a-z]+\s*[\(（]\d+[\)）]$"#, options: .regularExpression) != nil {
            return true
        }
        if value.range(of: #"^v?\d+(\.\d+)+"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func isPath(_ path: [Int], prefixOf other: [Int]) -> Bool {
        guard path.count <= other.count else { return false }
        return Array(other.prefix(path.count)) == path
    }

    static func hasTimeText(_ node: AXSnapshotNode) -> Bool {
        func visit(_ node: AXSnapshotNode) -> Bool {
            if node.role == "AXStaticText" {
                let value = node.value.isEmpty ? node.title : node.value
                if !value.isEmpty,
                   timePatterns.contains(where: {
                       $0.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                   }) {
                    return true
                }
            }
            return node.children.contains(where: visit)
        }
        return visit(node)
    }
}
