import Foundation

/// Codex 账户用量快照。数据来自 Codex app-server 的 `account/usage/read` 与
/// `account/rateLimits/read`；今日桶在服务端尚未结算时，用本机当天的
/// `token_count` 事件补齐（只读 token 元数据，不读聊天正文）。
nonisolated struct CodexUsageSnapshot: Equatable, Sendable {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case today, week, all

        var id: Self { self }
    }

    var todayTokens: Int64?
    var weekTokens: Int64?
    var lifetimeTokens: Int64?
    /// 0...100。nil 表示服务端没有返回周额度。
    var weeklyUsedPercent: Double?
    var weeklyResetsAt: Date?
    var plan: String?
    var resetCredits: Int?
    var updatedAt: Date
    /// 今日数字来自本机会话记录，而不是服务端日桶。
    var todayIsLocalEstimate = false

    func tokens(for period: Period) -> Int64? {
        switch period {
        case .today: todayTokens
        case .week: weekTokens
        case .all: lifetimeTokens
        }
    }

    var weeklyRemainingPercent: Int? {
        guard let weeklyUsedPercent else { return nil }
        return min(100, max(0, Int((100 - weeklyUsedPercent).rounded())))
    }

    var planName: String? {
        guard let plan, !plan.isEmpty else { return nil }
        switch plan.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "promax": return "Pro Max"
        case "free": return String(localized: "免费", bundle: .l10n)
        case "go": return "Go"
        case "team": return String(localized: "团队", bundle: .l10n)
        case "business", "self_serve_business_usage_based", "self_serve_business_prolite":
            return String(localized: "商业版", bundle: .l10n)
        case "enterprise", "enterprise_cbp_automation", "enterprise_cbp_usage_based":
            return String(localized: "企业版", bundle: .l10n)
        case "edu", "edu_plus", "edu_pro", "sci", "sci_plus":
            return String(localized: "教育版", bundle: .l10n)
        default: return plan
        }
    }
}

/// 只负责展示格式，便于单测。
nonisolated enum CodexUsageFormat {
    /// 4,938,713,816
    static func tokens(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 4.94B / 43.1M / 812K
    static func compactTokens(_ value: Int64) -> String {
        let units: [(Int64, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        for (unit, suffix) in units where value >= unit {
            let number = Double(value) / Double(unit)
            let text = number >= 100 ? String(format: "%.0f", number)
                : number >= 10 ? String(format: "%.1f", number)
                : String(format: "%.2f", number)
            return text + suffix
        }
        return String(value)
    }

    static func resetCountdown(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return String(localized: "即将重置", bundle: .l10n) }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return String(localized: "\(max(1, minutes))分钟后重置", bundle: .l10n)
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(localized: "\(hours)小时后重置", bundle: .l10n)
        }
        let days = hours / 24
        let rest = hours % 24
        return String(localized: "\(days)天\(rest)小时后重置", bundle: .l10n)
    }

    /// 设备端空间有限,用 4D 2H / 3H 20M / 12M / SOON。
    static func deviceReset(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "SOON" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))M" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)H \(minutes % 60)M" }
        return "\(hours / 24)D \(hours % 24)H"
    }

    static func updatedAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return String(localized: "更新于 \(formatter.string(from: date))", bundle: .l10n)
    }
}

nonisolated enum CodexUsageError: LocalizedError {
    case notInstalled
    case notAuthenticated
    case timeout
    case processExited
    case badResponse(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            String(localized: "未检测到 Codex CLI。安装并登录 Codex 后，这里会显示真实用量。", bundle: .l10n)
        case .notAuthenticated:
            String(localized: "Codex 未登录或用量暂不可用。", bundle: .l10n)
        case .timeout:
            String(localized: "读取超时，请稍后重试。", bundle: .l10n)
        case .processExited:
            String(localized: "Codex 用量进程已退出。", bundle: .l10n)
        case .badResponse(let detail), .requestFailed(let detail):
            String(localized: "读取失败：\(detail)", bundle: .l10n)
        }
    }
}

/// 通过 `codex app-server --stdio` 读取账户用量。每次刷新启动一个短生命周期进程，
/// 读到两个响应后立即退出；不写磁盘、不记录聊天内容。
nonisolated enum CodexUsageService {
    static func load(executable: URL? = locateExecutable(),
                     sessionRoot: URL = defaultSessionRoot,
                     now: Date = Date(),
                     calendar: Calendar = .iso8601WithLocalTimeZone) async throws -> CodexUsageSnapshot {
        guard let executable else { throw CodexUsageError.notInstalled }
        let responses = try await CodexAppServer.request(
            executable: executable,
            notifications: ["initialized"],
            requests: [
                (id: 1, method: "initialize", params: [
                    "clientInfo": ["name": "FoloVibeKey", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"],
                ]),
                (id: 2, method: "account/usage/read", params: [:]),
                (id: 3, method: "account/rateLimits/read", params: [:]),
            ])
        guard let usage = responses[2], let limits = responses[3] else {
            throw CodexUsageError.badResponse("missing account usage response")
        }
        return try CodexUsageParser.snapshot(usage: usage, rateLimits: limits, now: now,
                                             calendar: calendar, sessionRoot: sessionRoot)
    }

    nonisolated static var defaultSessionRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// 常见安装位置 + PATH。Finder 启动的 app 只有最小 PATH，所以显式列出。
    nonisolated static func locateExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            environment["IB_CODEX_BIN"],
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        ].compactMap { $0 }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }
}

nonisolated enum CodexUsageParser {
    private struct UsageWire: Decodable {
        struct Summary: Decodable {
            var lifetimeTokens: Int64?
        }
        struct Bucket: Decodable {
            var startDate: String
            var tokens: Int64
        }
        var summary: Summary
        var dailyUsageBuckets: [Bucket]?
    }

    private struct LimitsWire: Decodable {
        struct Window: Decodable {
            var usedPercent: Int
            var resetsAt: Int64?
            var windowDurationMins: Int64?
        }
        struct Snapshot: Decodable {
            var primary: Window?
            var secondary: Window?
            var planType: String?
        }
        struct ResetCredits: Decodable {
            var availableCount: Int
        }
        var rateLimits: Snapshot
        var rateLimitResetCredits: ResetCredits?
    }

    static func snapshot(usage: Data, rateLimits: Data, now: Date, calendar: Calendar,
                         sessionRoot: URL) throws -> CodexUsageSnapshot {
        let decoder = JSONDecoder()
        let usageWire: UsageWire
        do {
            usageWire = try decoder.decode(UsageWire.self, from: usage)
        } catch {
            throw CodexUsageError.badResponse(error.localizedDescription)
        }
        let limitsWire: LimitsWire
        do {
            limitsWire = try decoder.decode(LimitsWire.self, from: rateLimits)
        } catch {
            throw CodexUsageError.badResponse(error.localizedDescription)
        }

        let todayKey = dayKey(now, calendar: calendar)
        let weekStart = weekStartDate(now, calendar: calendar)
        let weekStartKey = dayKey(weekStart, calendar: calendar)
        let buckets = usageWire.dailyUsageBuckets ?? []

        let bucketToday = buckets.first(where: { $0.startDate == todayKey })?.tokens
        let localToday = bucketToday == nil
            ? localTodayTokens(sessionRoot: sessionRoot, day: now, calendar: calendar)
            : nil
        let today = bucketToday ?? localToday

        let weekFromBuckets = buckets
            .filter { $0.startDate >= weekStartKey && $0.startDate <= todayKey }
            .reduce(Int64(0)) { $0 + $1.tokens }
        let week = buckets.isEmpty ? nil : weekFromBuckets + (bucketToday == nil ? (localToday ?? 0) : 0)

        let window = limitsWire.rateLimits.secondary ?? limitsWire.rateLimits.primary
        let resetsAt = window?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return CodexUsageSnapshot(
            todayTokens: today,
            weekTokens: week,
            lifetimeTokens: usageWire.summary.lifetimeTokens,
            weeklyUsedPercent: window.map { Double($0.usedPercent) },
            weeklyResetsAt: resetsAt,
            plan: limitsWire.rateLimits.planType,
            resetCredits: limitsWire.rateLimitResetCredits?.availableCount,
            updatedAt: now,
            todayIsLocalEstimate: bucketToday == nil && localToday != nil)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func weekStartDate(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// 服务端的日桶按天结算，常常还没有今天的数字。只扫描今天的会话文件，
    /// 并且只解析含 `token_count` 的 JSON 行；不保存、不输出任何聊天内容。
    static func localTodayTokens(sessionRoot: URL, day: Date, calendar: Calendar) -> Int64? {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = components.year, let month = components.month, let date = components.day else { return nil }
        let folder = sessionRoot
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", date))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var total: Int64 = 0
        var found = false
        for file in files where file.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.contains("\"token_count\"") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let tokens = last["total_tokens"] as? NSNumber else { continue }
                total += tokens.int64Value
                found = true
            }
        }
        return found ? total : nil
    }
}

private extension Calendar {
    nonisolated static var iso8601WithLocalTimeZone: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }
}

/// 极简 JSON-RPC over stdio：发送几条请求，等指定 id 的结果。
nonisolated private enum CodexAppServer {
    static func request(executable: URL, notifications: [String] = [],
                        requests: [(id: Int, method: String, params: [String: Any])]) async throws -> [Int: Data] {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let collector = ResponseCollector(expected: Set(requests.map(\.id)))
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }
        process.terminationHandler = { _ in collector.fail(.processExited) }

        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.setContinuation(continuation)
                do {
                    try process.run()
                    for method in notifications {
                        let object: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": [:]]
                        var data = try JSONSerialization.data(withJSONObject: object)
                        data.append(0x0A)
                        try input.fileHandleForWriting.write(contentsOf: data)
                    }
                    for request in requests {
                        let object: [String: Any] = [
                            "jsonrpc": "2.0",
                            "id": request.id,
                            "method": request.method,
                            "params": request.params,
                        ]
                        var data = try JSONSerialization.data(withJSONObject: object)
                        data.append(0x0A)
                        try input.fileHandleForWriting.write(contentsOf: data)
                    }
                } catch {
                    collector.fail(.requestFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

nonisolated private final class ResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Set<Int>
    private var buffer = ""
    private var responses: [Int: Data] = [:]
    private var continuation: CheckedContinuation<[Int: Data], Error>?
    private var finished = false
    private var timeout: DispatchWorkItem?

    init(expected: Set<Int>) {
        self.expected = expected
        let item = DispatchWorkItem { [weak self] in self?.fail(.timeout) }
        timeout = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: item)
    }

    deinit { timeout?.cancel() }

    func setContinuation(_ continuation: CheckedContinuation<[Int: Data], Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        lock.lock()
        buffer += chunk
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        buffer = String(lines.last ?? "")
        let complete = lines.dropLast().map(String.init)
        lock.unlock()
        for line in complete { parse(line) }
    }

    private func parse(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else { return }
        if let error = object["error"] as? [String: Any] {
            fail(.requestFailed((error["message"] as? String) ?? "Codex app-server error"))
            return
        }
        guard let result = object["result"] as? [String: Any],
              let resultData = try? JSONSerialization.data(withJSONObject: result) else { return }
        lock.lock()
        responses[id] = resultData
        let done = expected.isSubset(of: Set(responses.keys))
        lock.unlock()
        if done { finish() }
    }

    func fail(_ error: CodexUsageError) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        timeout?.cancel()
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let responses = self.responses
        timeout?.cancel()
        lock.unlock()
        continuation?.resume(returning: responses)
    }
}
