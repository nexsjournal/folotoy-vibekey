import Foundation

/// 设备 / Mac 共用的 Agent 用量摘要。数字保留原始值，显示时再格式化。
nonisolated struct AgentUsageSnapshot: Equatable, Sendable {
    var app: String
    var today: Int64?
    var week: Int64?
    var total: Int64?
    var weeklyLeftPercent: Int?
    var reset: String?
    var plan: String?
    var credits: Int?
    var ready: Bool

    static func unavailable(app: String) -> AgentUsageSnapshot {
        AgentUsageSnapshot(app: app, today: nil, week: nil, total: nil,
                           weeklyLeftPercent: nil, reset: nil, plan: nil, credits: nil, ready: true)
    }

    func device(tab: Int) -> DeviceUsage {
        DeviceUsage(
            app: app,
            today: today.map(CodexUsageFormat.tokens) ?? "",
            week: week.map(CodexUsageFormat.tokens) ?? "",
            total: total.map(CodexUsageFormat.tokens) ?? "",
            tab: tab,
            leftPercent: weeklyLeftPercent,
            reset: reset ?? "",
            plan: plan?.uppercased() ?? "",
            credits: credits,
            ready: ready
        )
    }
}

/// 选择当前 Agent 的用量来源。Codex 走官方 app-server；DSH NEXT 读本地
/// `session_projcache` 里单独的 `tokenUsage` 投影；没有公开接口的 Agent 明确显示暂无数据。
nonisolated enum AgentUsageService {
    static func load(for app: AgentSessionApp) async -> AgentUsageSnapshot {
        switch app.bundleID {
        case AccessibilityCodexDesktopAdapter.bundleIdentifier:
            return await codex()
        case "ai.deepseek.dsh.desktop.next":
            return await DSHUsageReader.load()
        default:
            return .unavailable(app: app.shortName)
        }
    }

    private static func codex() async -> AgentUsageSnapshot {
        guard let snapshot = try? await CodexUsageService.load() else {
            return .unavailable(app: "CODEX")
        }
        return AgentUsageSnapshot(
            app: "CODEX",
            today: snapshot.todayTokens,
            week: snapshot.weekTokens,
            total: snapshot.lifetimeTokens,
            weeklyLeftPercent: snapshot.weeklyRemainingPercent,
            reset: snapshot.weeklyResetsAt.map { CodexUsageFormat.deviceReset($0) },
            plan: snapshot.plan,
            credits: snapshot.resetCredits,
            ready: true
        )
    }
}

/// DSH NEXT 的会话缓存把 token 用量放在独立的 `tokenUsage` 投影里。
/// 这里只读取每个文件开头的一小段，并只解析 `tokenUsage.val.totals`；
/// 不解析、不输出、不保存标题或聊天内容。
nonisolated enum DSHUsageReader {
    static func load() async -> AgentUsageSnapshot {
        await Task.detached(priority: .utility) { loadSync() }.value
    }

    private static func loadSync() -> AgentUsageSnapshot {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return .unavailable(app: "DSH") }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let now = Date()
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let todayStart = calendar.startOfDay(for: now)
        var total: Int64 = 0
        var today: Int64 = 0
        var week: Int64 = 0
        var found = false

        for file in files where file.pathExtension == "json" {
            guard let tokens = tokenTotal(in: file) else { continue }
            found = true
            total += tokens
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified >= todayStart { today += tokens }
            if modified >= weekStart { week += tokens }
        }
        guard found else { return .unavailable(app: "DSH") }
        return AgentUsageSnapshot(
            app: "DSH",
            today: today,
            week: week,
            total: total,
            weeklyLeftPercent: nil,
            reset: nil,
            plan: "DEEPSEEK",
            credits: nil,
            ready: true
        )
    }

    /// session_projcache 是格式化过的 JSON，tokenUsage 通常在前几 KB。只读 128 KB 前缀；
    /// 找到 `totals` 后按括号配对截取那一个小对象，再交给 JSONDecoder。
    private static func tokenTotal(in file: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 128 * 1024), !prefix.isEmpty else { return nil }
        let text = String(decoding: prefix, as: UTF8.self)
        guard let usage = text.range(of: "\"tokenUsage\""),
              let totals = text.range(of: "\"totals\"", range: usage.upperBound..<text.endIndex),
              let open = text.range(of: "{", range: totals.upperBound..<text.endIndex) else { return nil }
        guard let object = balancedObject(in: text, from: open.lowerBound) else { return nil }
        guard let data = object.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keys = ["uncachedInputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]
        var sum: Int64 = 0
        for key in keys {
            if let n = raw[key] as? NSNumber { sum += n.int64Value }
        }
        return sum > 0 ? sum : nil
    }

    /// 从 `{` 开始返回配对到 `}` 的子串（字符串里的括号不参与配对）。
    private static func balancedObject(in text: String, from start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
