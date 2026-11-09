import AppKit

/// 一个可做项目 / 会话导航的 Agent App。只保留跨异步任务需要的标识，AX 元素在每次操作前重新读取。
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
        AgentAppDisplayName.shortName(bundleID: bundleID, fallback: name)
    }

    /// 写入「设置 › Passport › 目标应用」的显示名；Codex 的 localizedName 是 ChatGPT，这里用产品名。
    var targetName: String {
        AgentAppDisplayName.targetName(bundleID: bundleID, fallback: name)
    }
}

/// 已知 Agent 的显示名。这里只影响设备上的标签，不参与「是否支持」的判断；
/// 未登记的 Agent（豆包工作、千问办公等）走通用 AX 解析，名字直接取 App 名。
nonisolated enum AgentAppDisplayName {
    private static let known: [String: (short: String, target: String)] = [
        "com.openai.codex": ("CODEX", "Codex"),
        "ai.deepseek.dsh.desktop.next": ("DSH", "DeepSeek"),
        "com.tencent.workbuddy.mac": ("WORKBUDDY", "WorkBuddy"),
        "dev.zcode.app": ("ZCODE", "ZCode"),
        "com.anthropic.claudefordesktop": ("CLAUDE", "Claude"),
        "com.anthropic.claude": ("CLAUDE", "Claude"),
        "com.alibaba.qwen.desktop": ("QWEN", "千问办公"),
        "com.bytedance.doubao.desktop": ("DOUBAO", "豆包工作"),
    ]

    static func shortName(bundleID: String, fallback: String) -> String {
        known[bundleID]?.short ?? String(fallback.prefix(8)).uppercased()
    }

    static func targetName(bundleID: String, fallback: String) -> String {
        known[bundleID]?.target ?? fallback
    }

    /// 用于“切到这个 App 时先显示用量首页”的判断；是否真的能读项目 / 会话仍由 AX 探测决定。
    static func isKnownAgent(bundleID: String) -> Bool {
        known[bundleID] != nil
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

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 只做纯字符串判断，便于单测；窗口标题在不同 Agent 上可能带应用后缀。
nonisolated enum AgentSessionNameMatcher {
    private static let suffixes = [
        " — DeepSeek Harness", " - DeepSeek Harness",
        " — WorkBuddy", " - WorkBuddy",
        " — ZCode", " - ZCode",
        " — Claude", " - Claude",
        " — Codex", " - Codex",
    ]

    static func normalizedWindowTitle(_ title: String) -> String {
        var result = title
        for suffix in suffixes {
            result = result.replacingOccurrences(of: suffix, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
