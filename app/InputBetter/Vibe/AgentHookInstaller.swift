import Foundation

/// 编程 Agent(Claude Code / Codex)的通知 hook 一键配置。
/// 两者的 hook 格式相同(`{"hooks": {事件: [{"hooks": [{"type": "command", "command": ...}]}]}}`),
/// 所以共用同一套合并逻辑,只是文件位置和事件名不同:
/// - Claude Code:`~/.claude/settings.json`,Stop → done、Notification → input、UserPromptSubmit → clear;
/// - Codex:`~/.codex/hooks.json`,Stop → done、PermissionRequest → input、UserPromptSubmit → clear。
/// 只追加本 app 的条目,保留已有配置;文件已存在时先备份为 `<文件>.inputbetter.bak`。
/// Codex 的 `notify` 设置不受影响(它只能有一个程序,可能已被其他工具使用)。
nonisolated enum AgentHookInstaller {
    enum Agent: String, CaseIterable, Identifiable, Sendable {
        case claudeCode, codex

        var id: String { rawValue }

        var name: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            }
        }

        /// 配置文件位置。
        var configURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeCode: return home.appendingPathComponent(".claude/settings.json")
            case .codex: return home.appendingPathComponent(".codex/hooks.json")
            }
        }

        /// Agent 事件 → InputBetter 通知事件。
        var events: [(hook: String, event: AgentNotifier.Event)] {
            switch self {
            case .claudeCode: [("Stop", .done), ("Notification", .input), ("UserPromptSubmit", .clear)]
            case .codex: [("Stop", .done), ("PermissionRequest", .input), ("UserPromptSubmit", .clear)]
            }
        }

        /// 安装后还需要用户做的事(Codex 需要在 CLI 里信任新 hook)。
        var followUp: String? {
            switch self {
            case .claudeCode: nil
            case .codex: String(localized: "在 Codex 里输入 /hooks 信任一次后生效", bundle: .l10n)
            }
        }
    }

    private static let marker = "inputbetter://agent"

    static func command(_ event: AgentNotifier.Event, agent: Agent) -> String {
        let source = agent.name.replacingOccurrences(of: " ", with: "%20")
        return "open -g '\(marker)?event=\(event.rawValue)&source=\(source)'"
    }

    static func isInstalled(_ agent: Agent, at url: URL? = nil) -> Bool {
        guard let text = try? String(contentsOf: url ?? agent.configURL, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// 合并写入 hook;重复执行不会产生重复条目。`url` 仅供测试指定文件。
    static func install(_ agent: Agent, at url: URL? = nil) throws {
        let file = url ?? agent.configURL
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "InputBetter", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    String(localized: "\(file.lastPathComponent) 不是有效的 JSON 对象", bundle: .l10n)])
            }
            root = parsed
            try data.write(to: file.appendingPathExtension("inputbetter.bak"))
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (hook, event) in agent.events {
            var groups = hooks[hook] as? [[String: Any]] ?? []
            let exists = groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains(marker) == true } == true
            }
            if !exists {
                groups.append(["hooks": [["type": "command", "command": command(event, agent: agent)]]])
            }
            hooks[hook] = groups
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }
}
