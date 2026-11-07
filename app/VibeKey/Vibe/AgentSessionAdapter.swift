import Foundation

/// 探测结果：`notReady` 表示 AX 树还没建好，值得重试；`notAgent` 表示树已读全但不像 Agent，
/// 立刻回退应用列表，避免在 Finder / 编辑器里白等两秒。
nonisolated enum AgentCatalogProbe: Sendable {
    case found(AgentSessionCatalog)
    case notAgent
    case notReady
}

/// 一个 Agent App 的侧栏适配器。调用前 App 已经被前置、AX 已经开启。
/// 适配器只读标题 / 角色 / 位置，不读取聊天正文。
@MainActor
protocol AgentSessionAdapter {
    /// 专门适配的 Bundle ID；通用适配器返回空集合。
    var bundleIDs: Set<String> { get }
    func probeCatalog(for app: AgentSessionApp) async -> AgentCatalogProbe
    func loadSessions(for project: AgentProject, in app: AgentSessionApp) async -> [AgentSession]
    func open(project: AgentProject?, session: AgentSession, in app: AgentSessionApp) async -> Bool
}

/// 已登记适配器 + 通用回退。新增 Agent 时优先什么都不做：
/// 通用 AX 解析能覆盖就用；结构特殊（Codex 的项目分组、DSH 的 AXOutline）才加专用适配器。
@MainActor
enum AgentSessionRegistry {
    static let known: [any AgentSessionAdapter] = [
        CodexAgentSessionAdapter(),
        DeepSeekAgentSessionAdapter(),
    ]
    static let generic = GenericAgentSessionAdapter()

    static func adapter(for bundleID: String) -> any AgentSessionAdapter {
        known.first { $0.bundleIDs.contains(bundleID) } ?? generic
    }

    static func isKnown(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return known.contains { $0.bundleIDs.contains(bundleID) }
    }
}
