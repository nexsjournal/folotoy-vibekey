import Foundation

/// 设备侧额度框的通用两行信息。Codex 填 5 小时 / 每周额度；其他 Agent
/// 可以填会话数、上下文、轮次、模型等本地元数据。
nonisolated struct AgentUsagePanel: Equatable, Sendable {
    var label1: String
    var value1: String
    var percent1: Int?
    var label2: String
    var value2: String
    var percent2: Int?
    var detail: String
    var footerLeft: String
    var footerRight: String
}

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
    var fiveHourLeftPercent: Int? = nil
    var fiveHourReset: String? = nil
    var panel: AgentUsagePanel? = nil

    static func unavailable(app: String) -> AgentUsageSnapshot {
        AgentUsageSnapshot(app: app, today: nil, week: nil, total: nil,
                           weeklyLeftPercent: nil, reset: nil, plan: nil, credits: nil, ready: true)
    }

    func device(tab: Int) -> DeviceUsage {
        let panel = panel ?? AgentUsagePanel(
            label1: "5H LEFT",
            value1: fiveHourLeftPercent.map { "\($0)%" } ?? "NO DATA",
            percent1: fiveHourLeftPercent,
            label2: "WEEK LEFT",
            value2: weeklyLeftPercent.map { "\($0)%" } ?? "NO DATA",
            percent2: weeklyLeftPercent,
            detail: reset.map { "RESET \($0)" } ?? "RESET --",
            footerLeft: "PLAN \(plan?.uppercased() ?? "--")",
            footerRight: credits.map { "CREDITS \($0)" } ?? "CREDITS --"
        )
        return DeviceUsage(
            app: app,
            today: today.map(CodexUsageFormat.tokens) ?? "",
            week: week.map(CodexUsageFormat.tokens) ?? "",
            total: total.map(CodexUsageFormat.tokens) ?? "",
            tab: tab,
            leftPercent: weeklyLeftPercent,
            reset: reset ?? "",
            plan: plan?.uppercased() ?? "",
            credits: credits,
            ready: ready,
            fiveHourLeftPercent: fiveHourLeftPercent,
            fiveHourReset: fiveHourReset ?? "",
            panel1Label: panel.label1,
            panel1Value: panel.value1,
            panel1Percent: panel.percent1,
            panel2Label: panel.label2,
            panel2Value: panel.value2,
            panel2Percent: panel.percent2,
            panelDetail: panel.detail,
            panelFooterLeft: panel.footerLeft,
            panelFooterRight: panel.footerRight
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
        case "com.anthropic.claudefordesktop", "com.anthropic.claude":
            return await ClaudeUsageReader.load()
        case "dev.zcode.app":
            return await ZCodeUsageReader.load()
        case "com.tencent.workbuddy.mac":
            return await WorkBuddyUsageReader.load()
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
            ready: true,
            fiveHourLeftPercent: snapshot.fiveHourRemainingPercent,
            fiveHourReset: snapshot.fiveHourResetsAt.map { CodexUsageFormat.deviceReset($0) }
        )
    }
}

/// DSH NEXT 的会话缓存包含 tokenUsage / sessionStats / contextPressure /
/// modelSelection 元数据。这里只读这些字段，不解析、不输出、不保存标题或聊天内容。
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
        var sessions = 0
        var turns = 0
        var found = false
        var foundTokens = false
        var model: String?
        var contextPercent: Int?
        var lastActivity: Date?

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = root["record"] as? [String: Any],
                  let rows = record["rows"] as? [String: Any] else { continue }
            found = true
            sessions += 1

            let tokenTotal = dshTokenTotal(rows)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if let tokenTotal, tokenTotal > 0 {
                foundTokens = true
                total += tokenTotal
                if modified >= todayStart { today += tokenTotal }
                if modified >= weekStart { week += tokenTotal }
            }
            turns += dshSessionTurns(rows)

            let promptAt = dshLastPrompt(rows)
            let activity = promptAt ?? modified
            if lastActivity == nil || activity > lastActivity! {
                lastActivity = activity
                let latestModel = dshModel(rows)
                if let latestModel { model = latestModel }
                contextPercent = dshContextPercent(rows)
            } else if model == nil {
                model = dshModel(rows)
            }
        }
        guard found else { return .unavailable(app: "DSH") }
        let panel = AgentUsagePanel(
            label1: "CONTEXT",
            value1: contextPercent.map { "\($0)%" } ?? "--",
            percent1: contextPercent,
            label2: "SESSIONS",
            value2: AgentUsageFormat.count(sessions),
            percent2: nil,
            detail: "LAST \(AgentUsageFormat.ago(lastActivity))",
            footerLeft: AgentUsageFormat.model(model) ?? "DEEPSEEK",
            footerRight: "TURNS \(AgentUsageFormat.count(turns))"
        )
        return AgentUsageSnapshot(
            app: "DSH",
            today: foundTokens ? today : nil,
            week: foundTokens ? week : nil,
            total: foundTokens ? total : nil,
            weeklyLeftPercent: nil,
            reset: nil,
            plan: "DEEPSEEK",
            credits: nil,
            ready: true,
            panel: panel
        )
    }

    private static func rowValue(_ rows: [String: Any], _ key: String) -> [String: Any]? {
        (rows[key] as? [String: Any])?["val"] as? [String: Any]
    }

    private static func dshTokenTotal(_ rows: [String: Any]) -> Int64? {
        guard let usage = rowValue(rows, "tokenUsage"),
              let totals = usage["totals"] as? [String: Any] else { return nil }
        let keys = ["uncachedInputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]
        let sum = keys.reduce(Int64(0)) { partial, key in
            partial + ((totals[key] as? NSNumber)?.int64Value ?? 0)
        }
        return sum > 0 ? sum : nil
    }

    private static func dshSessionTurns(_ rows: [String: Any]) -> Int {
        ((rowValue(rows, "sessionStats")?["turns"] as? NSNumber)?.intValue) ?? 0
    }

    private static func dshModel(_ rows: [String: Any]) -> String? {
        let last = rowValue(rows, "modelSelection")?["lastUsed"] as? [String: Any]
        return last?["model"] as? String
    }

    private static func dshContextPercent(_ rows: [String: Any]) -> Int? {
        guard let pressure = rowValue(rows, "contextPressure"),
              let surface = (pressure["surfaceTokens"] as? NSNumber)?.doubleValue,
              let window = (pressure["contextWindow"] as? NSNumber)?.doubleValue,
              window > 0 else { return nil }
        return min(100, max(0, Int((surface * 100 / window).rounded())))
    }

    private static func dshLastPrompt(_ rows: [String: Any]) -> Date? {
        guard let ms = (rowValue(rows, "sessionListMetadata")?["lastPromptAt"] as? NSNumber)?.doubleValue,
              ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
