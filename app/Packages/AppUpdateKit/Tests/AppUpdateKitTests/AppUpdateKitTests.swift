import Foundation
import Testing
@testable import AppUpdateKit

/// 版本比较、更新结论与检查调度(不联网,数据源用 StaticUpdateFeed / 计数源)。
struct AppVersionTests {
    @Test func parsesDottedNumbers() throws {
        #expect(AppVersion("0.1.4")?.parts == [0, 1, 4])
        #expect(AppVersion("1")?.parts == [1])
        for bad in ["", "1.", ".1", "v1.2", "1.2-beta", "1.2.3.4.5", "１.2", "123456"] { #expect(AppVersion(bad) == nil, "\(bad)") }
        #expect(AppVersion("1.2", build: "x") == nil)
        #expect(try #require(AppVersion("1.2", build: "42")).build == 42)
    }

    @Test func comparesLikeTheConsole() throws {
        let v = { (s: String, b: String?) in AppVersion(s, build: b)! }
        #expect(v("1.2", nil) == v("1.2.0", nil))
        #expect(v("1.10", nil) > v("1.9.9", nil))
        #expect(v("1.4.0", "11") < v("1.4", "12"))
        #expect(v("1.4.0", nil) == v("1.4", "12"), "缺构建号时不比较构建号")
        #expect(v("0.1.4", nil).description == "0.1.4")
    }
}

struct UpdateVerdictTests {
    private func result(_ latest: String, build: String? = nil, required: String? = nil) -> UpdateFeedResult {
        UpdateFeedResult(latest: UpdateRelease(version: AppVersion(latest, build: build)!, downloadURL: URL(string: "https://example.com/a.dmg")!),
                         requiredAtOrBelow: required.flatMap { AppVersion($0) })
    }

    @Test func matchesConsoleRules() {
        let feed = result("1.4.0", build: "12", required: "1.2")
        let cases: [(String, String?, String)] = [("1.1.9", nil, "required"), ("1.2", nil, "required"), ("1.2.0.0", nil, "required"),
                                                  ("1.2.1", nil, "available"), ("1.4.0", "11", "available"), ("1.4", "12", "none"),
                                                  ("1.4.0", nil, "none"), ("2.0", nil, "none")]
        for (version, build, expected) in cases {
            let verdict = UpdateVerdict.evaluate(current: AppVersion(version, build: build)!, result: feed)
            let name = switch verdict { case .upToDate: "none"; case .available: "available"; case .required: "required" }
            #expect(name == expected, "\(version) (\(build ?? "-"))")
        }
        #expect(UpdateVerdict.evaluate(current: AppVersion("0.1")!, result: UpdateFeedResult(latest: nil)) == .upToDate)
        // 后台误把强制版本设得 ≥ 最新版本时,已是最新的客户端不受影响。
        #expect(UpdateVerdict.evaluate(current: AppVersion("1.4")!, result: result("1.4", required: "9.9")) == .upToDate)
    }

    @Test func picksNotesForLanguage() {
        let release = UpdateRelease(version: AppVersion("1.0")!, notes: ["zh": "修复", "en": " "], downloadURL: URL(string: "https://e.com")!)
        #expect(release.notes(for: "zh-Hans") == "修复")
        #expect(release.notes(for: "en") == "修复", "英文为空时退回其他语言")
    }
}

@MainActor
struct UpdateCheckerTests {
    private func checker(_ result: UpdateFeedResult, current: String = "1.0", defaults: UserDefaults) -> (UpdateChecker, Recorder) {
        let checker = UpdateChecker(feed: StaticUpdateFeed(result), currentVersion: AppVersion(current)!,
                                    preferences: UpdatePreferences(defaults: defaults))
        let recorder = Recorder()
        checker.present = { recorder.events.append($0) }
        return (checker, recorder)
    }
    private func freshDefaults() -> UserDefaults {
        let name = "AppUpdateKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
    private let newer = UpdateRelease(version: AppVersion("1.1")!, downloadURL: URL(string: "https://example.com/a.dmg")!)

    @Test func automaticChecksRespectSkippedVersionButManualDoesNot() async {
        let defaults = freshDefaults()
        let (checker, recorder) = checker(UpdateFeedResult(latest: newer), defaults: defaults)
        await checker.check(userInitiated: false)
        #expect(recorder.events == [.update(newer, required: false)])
        checker.skip(newer)
        await checker.check(userInitiated: false)
        #expect(recorder.events.count == 1, "跳过的版本自动检查不再提示")
        await checker.check(userInitiated: true)
        #expect(recorder.events.last == .update(newer, required: false), "手动检查仍然提示")
        #expect(checker.lastChecked != nil)
    }

    @Test func requiredUpdatesIgnoreSkip() async {
        let defaults = freshDefaults()
        let (checker, recorder) = checker(UpdateFeedResult(latest: newer, requiredAtOrBelow: AppVersion("1.0")), defaults: defaults)
        checker.skip(newer)
        await checker.check(userInitiated: false)
        #expect(recorder.events == [.update(newer, required: true)])
        #expect(checker.verdict == .required(newer))
    }

    @Test func upToDateAndFailuresOnlyReportedWhenManual() async {
        let defaults = freshDefaults()
        let (checker, recorder) = checker(UpdateFeedResult(latest: newer), current: "1.1", defaults: defaults)
        await checker.check(userInitiated: false)
        #expect(recorder.events.isEmpty)
        await checker.check(userInitiated: true)
        #expect(recorder.events == [.upToDate])

        let failing = UpdateChecker(feed: FailingFeed(), currentVersion: AppVersion("1.0")!, preferences: UpdatePreferences(defaults: defaults))
        let failures = Recorder()
        failing.present = { failures.events.append($0) }
        await failing.check(userInitiated: false)
        #expect(failures.events.isEmpty)
        await failing.check(userInitiated: true)
        if case .failed = failures.events.first {} else { Issue.record("手动检查失败要报告") }
    }

    @Test func preferencesPersist() {
        let defaults = freshDefaults()
        let (checker, _) = checker(UpdateFeedResult(latest: nil), defaults: defaults)
        #expect(checker.automaticChecks)
        checker.automaticChecks = false
        #expect(UpdatePreferences(defaults: defaults).automaticChecks == false)
    }
}

@MainActor private final class Recorder { var events: [UpdateEvent] = [] }
private struct FailingFeed: UpdateFeed {
    func fetch() async throws -> UpdateFeedResult { throw URLError(.notConnectedToInternet) }
}

struct JSONUpdateFeedTests {
    @Test func decodesConsoleResponse() throws {
        let json = #"{"platform":"macos","latest":{"version":"1.4.0","build":"12","notes":{"zh":"修复","en":"Fixes"},"url":"https://example.com/A-1.4.0.dmg","publishedAt":1760000000000},"requiredAtOrBelow":"1.2","status":null}"#
        let result = try JSONUpdateFeed.decode(Data(json.utf8))
        #expect(result.latest?.version == AppVersion("1.4.0", build: "12"))
        #expect(result.latest?.notes["en"] == "Fixes")
        #expect(result.latest?.publishedAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(result.requiredAtOrBelow == AppVersion("1.2"))
    }

    @Test func acceptsEmptyAndRejectsUnsafe() throws {
        #expect(try JSONUpdateFeed.decode(Data(#"{"latest":null,"requiredAtOrBelow":""}"#.utf8)) == UpdateFeedResult(latest: nil))
        for bad in [#"{"latest":{"version":"1.0","url":"http://example.com/a.dmg"}}"#,
                    #"{"latest":{"version":"v1","url":"https://example.com/a.dmg"}}"#,
                    #"{"latest":null,"requiredAtOrBelow":"x"}"#, "[]", "oops"] {
            #expect(throws: JSONUpdateFeed.FeedError.invalidResponse) { try JSONUpdateFeed.decode(Data(bad.utf8)) }
        }
    }
}
