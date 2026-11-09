import Foundation

/// 设备 USAGE 页的短文本格式。只用于本地 Agent 元数据，不读取聊天正文。
nonisolated enum AgentUsageFormat {
    static func count(_ value: Int) -> String {
        value < 1000 ? String(value) : CodexUsageFormat.compactTokens(Int64(value))
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "NOW" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)M" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)H" }
        return "\(hours / 24)D"
    }

    static func model(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !value.isEmpty else { return nil }
        return String(value.prefix(14))
    }
}

/// Claude Code 的会话 JSONL：只读取 assistant 消息里的 model / usage / timestamp。
nonisolated enum ClaudeUsageReader {
    static func load() async -> AgentUsageSnapshot {
        await Task.detached(priority: .utility) { loadSync() }.value
    }

    private static func loadSync() -> AgentUsageSnapshot {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return .unavailable(app: "CLAUDE") }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        var sessions = 0
        var projects = Set<String>()
        var turns = 0
        var total: Int64 = 0
        var today: Int64 = 0
        var week: Int64 = 0
        var foundUsage = false
        var model: String?
        var lastActivity: Date?

        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            sessions += 1
            projects.insert(file.deletingLastPathComponent().lastPathComponent)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let tokens = claudeTokenTotal(usage)
                guard tokens > 0 else { continue }
                foundUsage = true
                turns += 1
                total += tokens
                let date = parseISO(object["timestamp"] as? String)
                    ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                if date >= todayStart { today += tokens }
                if date >= weekStart { week += tokens }
                if lastActivity == nil || date > lastActivity! {
                    lastActivity = date
                    model = message["model"] as? String
                } else if model == nil {
                    model = message["model"] as? String
                }
            }
        }
        guard sessions > 0 else { return .unavailable(app: "CLAUDE") }
        let panel = AgentUsagePanel(
            label1: "SESSIONS",
            value1: AgentUsageFormat.count(sessions),
            percent1: nil,
            label2: "TURNS",
            value2: AgentUsageFormat.count(turns),
            percent2: nil,
            detail: "LAST \(AgentUsageFormat.ago(lastActivity))",
            footerLeft: AgentUsageFormat.model(model) ?? "CLAUDE CODE",
            footerRight: "PROJECTS \(AgentUsageFormat.count(projects.count))"
        )
        return AgentUsageSnapshot(
            app: "CLAUDE",
            today: foundUsage ? today : nil,
            week: foundUsage ? week : nil,
            total: foundUsage ? total : nil,
            weeklyLeftPercent: nil,
            reset: nil,
            plan: "CLAUDE CODE",
            credits: nil,
            ready: true,
            panel: panel
        )
    }

    private static func claudeTokenTotal(_ usage: [String: Any]) -> Int64 {
        ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(Int64(0)) { $0 + ((usage[$1] as? NSNumber)?.int64Value ?? 0) }
    }
}

/// ZCode 的 rollout 记录每一次模型请求，response.usage 带 token 计数。
nonisolated enum ZCodeUsageReader {
    static func load() async -> AgentUsageSnapshot {
        await Task.detached(priority: .utility) { loadSync() }.value
    }

    private static func loadSync() -> AgentUsageSnapshot {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/rollout", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return .unavailable(app: "ZCODE") }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        var sessions = 0
        var requests = 0
        var total: Int64 = 0
        var today: Int64 = 0
        var week: Int64 = 0
        var foundUsage = false
        var model: String?
        var lastActivity: Date?

        for file in files where file.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var fileHasUsage = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let response = object["response"] as? [String: Any],
                      let usage = response["usage"] as? [String: Any] else { continue }
                let tokens = (usage["totalTokens"] as? NSNumber)?.int64Value
                    ?? ((usage["inputTokens"] as? NSNumber)?.int64Value ?? 0)
                        + ((usage["outputTokens"] as? NSNumber)?.int64Value ?? 0)
                guard tokens > 0 else { continue }
                fileHasUsage = true
                foundUsage = true
                requests += 1
                total += tokens
                let date = parseISO(object["startedAt"] as? String)
                    ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                if date >= todayStart { today += tokens }
                if date >= weekStart { week += tokens }
                if lastActivity == nil || date > lastActivity! {
                    lastActivity = date
                    model = response["modelId"] as? String
                        ?? ((object["model"] as? [String: Any])?["modelId"] as? String)
                } else if model == nil {
                    model = response["modelId"] as? String
                        ?? ((object["model"] as? [String: Any])?["modelId"] as? String)
                }
            }
            if fileHasUsage { sessions += 1 }
        }
        guard foundUsage else { return .unavailable(app: "ZCODE") }
        let panel = AgentUsagePanel(
            label1: "SESSIONS",
            value1: AgentUsageFormat.count(sessions),
            percent1: nil,
            label2: "REQUESTS",
            value2: AgentUsageFormat.count(requests),
            percent2: nil,
            detail: "LAST \(AgentUsageFormat.ago(lastActivity))",
            footerLeft: AgentUsageFormat.model(model) ?? "ZCODE",
            footerRight: ""
        )
        return AgentUsageSnapshot(
            app: "ZCODE",
            today: today,
            week: week,
            total: total,
            weeklyLeftPercent: nil,
            reset: nil,
            plan: "ZCODE",
            credits: nil,
            ready: true,
            panel: panel
        )
    }
}

/// WorkBuddy 的 trace 第一行有 totalTokens / spanCount / startedAt。
nonisolated enum WorkBuddyUsageReader {
    static func load() async -> AgentUsageSnapshot {
        await Task.detached(priority: .utility) { loadSync() }.value
    }

    private static func loadSync() -> AgentUsageSnapshot {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/traces", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return .unavailable(app: "WORKBUDDY") }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        var traces = 0
        var spans = 0
        var total: Int64 = 0
        var today: Int64 = 0
        var week: Int64 = 0
        var lastActivity: Date?

        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            let first = jsonLine(firstLine(of: file))
            let last = jsonLine(lastLine(of: file))
            guard let trace = (last?["trace"] as? [String: Any])
                ?? (first?["trace"] as? [String: Any]) else { continue }
            traces += 1
            spans += (trace["spanCount"] as? NSNumber)?.intValue ?? 0
            let tokens = (trace["totalTokens"] as? NSNumber)?.int64Value ?? 0
            total += tokens
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let started = parseISO(trace["startedAt"] as? String) ?? modified
            if started >= todayStart { today += tokens }
            if started >= weekStart { week += tokens }
            let activity = max(modified, started)
            if lastActivity == nil || activity > lastActivity! { lastActivity = activity }
        }
        guard traces > 0 else { return .unavailable(app: "WORKBUDDY") }
        let panel = AgentUsagePanel(
            label1: "TRACES",
            value1: AgentUsageFormat.count(traces),
            percent1: nil,
            label2: "SPANS",
            value2: AgentUsageFormat.count(spans),
            percent2: nil,
            detail: "LAST \(AgentUsageFormat.ago(lastActivity))",
            footerLeft: "WORKBUDDY",
            footerRight: total > 0 ? "TOKENS \(CodexUsageFormat.compactTokens(total))" : ""
        )
        return AgentUsageSnapshot(
            app: "WORKBUDDY",
            today: today,
            week: week,
            total: total,
            weeklyLeftPercent: nil,
            reset: nil,
            plan: "WORKBUDDY",
            credits: nil,
            ready: true,
            panel: panel
        )
    }

    private static func firstLine(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
    }

    private static func lastLine(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > 64 * 1024 ? end - 64 * 1024 : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init)
    }

    private static func jsonLine(_ line: String?) -> [String: Any]? {
        guard let line, let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

nonisolated private func parseISO(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
