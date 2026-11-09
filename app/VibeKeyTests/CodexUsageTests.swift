import Foundation
import Testing
@testable import VibeKey

struct CodexUsageTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: string)!
    }

    @Test func parsesTodayWeekLifetimeAndQuota() throws {
        let usage = Data("""
        {"summary":{"lifetimeTokens":1000},"dailyUsageBuckets":[
          {"startDate":"2026-11-02","tokens":50},
          {"startDate":"2026-11-09","tokens":70},
          {"startDate":"2026-11-10","tokens":30},
          {"startDate":"2026-11-11","tokens":100}
        ]}
        """.utf8)
        let limits = Data("""
        {"rateLimits":{"secondary":{"usedPercent":93,"resetsAt":1794578790},
          "planType":"plus"},"rateLimitResetCredits":{"availableCount":2}}
        """.utf8)
        let snapshot = try CodexUsageParser.snapshot(
            usage: usage, rateLimits: limits,
            now: date("2026-11-11T19:00:00+08:00"), calendar: calendar,
            sessionRoot: URL(fileURLWithPath: "/nonexistent"))

        #expect(snapshot.todayTokens == 100)
        #expect(snapshot.weekTokens == 200)
        #expect(snapshot.lifetimeTokens == 1000)
        #expect(snapshot.weeklyRemainingPercent == 7)
        #expect(snapshot.planName == "Plus")
        #expect(snapshot.resetCredits == 2)
        #expect(!snapshot.todayIsLocalEstimate)
    }

    @Test func fallsBackToLocalSessionForToday() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("2026/11/11")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = """
        {"timestamp":"2026-11-11T10:00:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42}},"rate_limits":{}}}
        """
        try (line + "\n").write(to: folder.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let usage = Data("""
        {"summary":{"lifetimeTokens":500},"dailyUsageBuckets":[
          {"startDate":"2026-11-09","tokens":50}
        ]}
        """.utf8)
        let limits = Data("""
        {"rateLimits":{"secondary":{"usedPercent":10}}}
        """.utf8)
        let snapshot = try CodexUsageParser.snapshot(
            usage: usage, rateLimits: limits,
            now: date("2026-11-11T19:00:00+08:00"), calendar: calendar,
            sessionRoot: root)

        #expect(snapshot.todayTokens == 42)
        #expect(snapshot.weekTokens == 92)
        #expect(snapshot.todayIsLocalEstimate)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func missingBucketsDoesNotPretendWeekIsZero() throws {
        let usage = Data(#"{"summary":{"lifetimeTokens":123}}"#.utf8)
        let limits = Data(#"{"rateLimits":{}}"#.utf8)
        let snapshot = try CodexUsageParser.snapshot(
            usage: usage, rateLimits: limits,
            now: date("2026-11-09T19:00:00+08:00"), calendar: calendar,
            sessionRoot: URL(fileURLWithPath: "/nonexistent"))

        #expect(snapshot.todayTokens == nil)
        #expect(snapshot.weekTokens == nil)
        #expect(snapshot.lifetimeTokens == 123)
        #expect(snapshot.weeklyRemainingPercent == nil)
    }

    @Test func formatsTokenCounts() {
        #expect(CodexUsageFormat.tokens(1_234_567) == "1,234,567")
        #expect(CodexUsageFormat.compactTokens(4_938_713_816) == "4.94B")
        #expect(CodexUsageFormat.compactTokens(43_051_522) == "43.1M")
        #expect(CodexUsageFormat.compactTokens(812) == "812")
    }

    @Test func resetCountdownUsesDaysAndHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(6 * 86_400 + 3 * 3_600)
        let text = CodexUsageFormat.resetCountdown(reset, now: now)
        #expect(text.contains("6"))
        #expect(text.contains("3"))
    }
}
