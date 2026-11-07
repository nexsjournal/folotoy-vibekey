import Foundation

/// 编程 Agent(Claude Code / Codex)的通知 hook 一键配置。
/// 两者的 hook 格式相同(`{"hooks": {事件: [{"hooks": [{"type": "command", "command": ...}]}]}}`),
/// 所以共用同一套合并逻辑,只是文件位置和事件名不同:
/// - Claude Code:`~/.claude/settings.json`,Stop → done、Notification → input、UserPromptSubmit → clear;
/// - Codex:`~/.codex/hooks.json`,Stop → done、PermissionRequest → input、UserPromptSubmit → clear。
/// 只追加本 app 的条目,保留已有配置;文件已存在时先备份为 `<文件>.folobutton-dev.bak`。
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

        /// Agent 事件 → VibeKey 通知事件。
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

    private static let marker = "folobutton-dev://agent"

    static func command(_ event: AgentNotifier.Event, agent: Agent) -> String {
        if agent == .codex, event == .done {
            // 只传会话、轮次和经过裁剪的项目名，Hook 原始 JSON 留在进程内。
            return #"""
            payload=$(/bin/cat)
            thread=$(printf '%s' "$payload" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null) || exit 0
            case "$thread" in ''|*[!0-9A-Fa-f-]*) exit 0 ;; esac
            turn=$(printf '%s' "$payload" | /usr/bin/plutil -extract turn_id raw -o - - 2>/dev/null) || turn=
            case "$turn" in *[!0-9A-Za-z_-]*) turn= ;; esac
            cwd=$(printf '%s' "$payload" | /usr/bin/plutil -extract cwd raw -o - - 2>/dev/null) || cwd=
            project=$(printf '%s' "${cwd##*/}" | LC_ALL=C /usr/bin/tr -cd 'A-Za-z0-9._-' | /usr/bin/cut -c 1-15)
            /usr/bin/open -g -b local.folobutton.dev "folobutton-dev://agent?event=done&source=Codex&thread=$thread&turn=$turn&project=$project"
            """#
        }
        let source = agent.name.replacingOccurrences(of: " ", with: "%20")
        return "open -g '\(marker)?event=\(event.rawValue)&source=\(source)'"
    }

    static func isInstalled(_ agent: Agent, at url: URL? = nil) -> Bool {
        guard let text = try? String(contentsOf: url ?? agent.configURL, encoding: .utf8) else { return false }
        return text.contains(agent == .codex ? "&thread=$thread&turn=$turn" : marker)
    }

    /// 合并写入 hook;重复执行不会产生重复条目。`url` 仅供测试指定文件。
    static func install(_ agent: Agent, at url: URL? = nil) throws {
        let file = url ?? agent.configURL
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "VibeKey", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    String(localized: "\(file.lastPathComponent) 不是有效的 JSON 对象", bundle: .l10n)])
            }
            root = parsed
            try backupOnce(data, beside: file)
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (hook, event) in agent.events {
            var groups = hooks[hook] as? [[String: Any]] ?? []
            if agent == .codex, event == .done {
                // 原位升级旧命令，保留同组用户 Hook 和运行选项。
                let old = "open -g '\(marker)?event=done&source=Codex'"
                for index in groups.indices {
                    guard var entries = groups[index]["hooks"] as? [[String: Any]] else { continue }
                    for entry in entries.indices where entries[entry]["command"] as? String == old {
                        entries[entry]["command"] = command(event, agent: agent)
                    }
                    groups[index]["hooks"] = entries
                }
            }
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

    /// 首次安装时保存原配置;重复安装不覆盖这份备份。临时文件和备份均只允许本人读取。
    private static func backupOnce(_ data: Data, beside file: URL) throws {
        let backup = file.appendingPathExtension("folobutton-dev.bak")
        let temp = file.deletingLastPathComponent().appendingPathComponent(".folobutton-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if link(temp.path, backup.path) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
