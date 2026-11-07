import XCTest
@testable import VibeKey

/// 不依赖硬件和模型的核心逻辑测试。
nonisolated final class CoreLogicTests: XCTestCase {
    // MARK: 按住说话 / 短按免提

    func testHoldToTalkStopsOnRelease() {
        var p = PressInterpreter()
        let t0: TimeInterval = 100
        XCTAssertEqual(p.down(at: t0), .start)
        XCTAssertEqual(p.up(at: t0 + 1.0), .stop)
        XCTAssertFalse(p.isActive)
    }

    func testShortTapEntersHandsFreeAndSecondPressStops() {
        var p = PressInterpreter()
        let t0: TimeInterval = 100
        XCTAssertEqual(p.down(at: t0), .start)
        XCTAssertEqual(p.up(at: t0 + 0.1), .none)
        XCTAssertTrue(p.isHandsFree)
        XCTAssertEqual(p.down(at: t0 + 3), .stop)
        XCTAssertEqual(p.up(at: t0 + 3.1), .none)
        XCTAssertFalse(p.isActive)
    }

    func testPassportShortPressCancelsAndHoldStopsOnRelease() {
        var p = PressInterpreter()
        let t0: TimeInterval = 100
        XCTAssertEqual(p.down(at: t0, style: .pushToTalk), .start)
        XCTAssertEqual(p.up(at: t0 + 0.2), .cancel)
        XCTAssertFalse(p.isHandsFree)
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.down(at: t0 + 1, style: .pushToTalk), .start)
        XCTAssertEqual(p.up(at: t0 + 1.3), .stop)
        XCTAssertFalse(p.isActive)
    }

    // MARK: 文本拼接

    func testJoinCJKWithoutSpaces() {
        XCTAssertEqual(TranscriptText.join(["今天天气不错,", "我们去散步吧。"]), "今天天气不错,我们去散步吧。")
    }

    func testJoinLatinWithSpaces() {
        XCTAssertEqual(TranscriptText.join(["Hello world.", "How are you?"]), "Hello world. How are you?")
    }

    func testJoinMixed() {
        XCTAssertEqual(TranscriptText.join(["打开", "SwiftUI", "文档"]), "打开SwiftUI文档")
    }

    func testHallucinationFilter() {
        XCTAssertTrue(TranscriptText.isHallucination("字幕由Amara.org社区提供"))
        XCTAssertTrue(TranscriptText.isHallucination("。"))
        XCTAssertFalse(TranscriptText.isHallucination("帮我订阅这个频道的更新通知然后把结果发到群里,顺便看看明天的天气"))
    }

    func testSimplified() {
        XCTAssertEqual(TranscriptText.toSimplified("這是測試"), "这是测试")
    }

    // MARK: LLM 响应解析

    func testParseCompletionStripsThinking() throws {
        let json = #"{"choices":[{"message":{"content":"<think>hmm</think>\n你好,世界。"}}]}"#
        XCTAssertEqual(try LLMClient.parseCompletion(Data(json.utf8)), "你好,世界。")
    }

    func testParseCompletionEmptyThrows() {
        let json = #"{"choices":[{"message":{"content":"  "}}]}"#
        XCTAssertThrowsError(try LLMClient.parseCompletion(Data(json.utf8)))
    }

    func testSubtitlePromptIncludesContext() {
        let user = Prompts.subtitleUser(current: "c", context: [(source: "a", translation: nil), (source: "b", translation: nil)])
        XCTAssertTrue(user.contains("PREVIOUS:\na\nb"))
        XCTAssertTrue(user.hasSuffix("CURRENT: c"))
    }

    // MARK: Agent 通知 URL

    @MainActor
    func testAgentURLParsing() {
        let notifier = AgentNotifier()
        XCTAssertTrue(notifier.handle(url: URL(string: "folobutton-dev://agent?event=input&source=Claude%20Code")!))
        XCTAssertEqual(notifier.current?.event, .input)
        XCTAssertEqual(notifier.current?.source, "Claude Code")
        notifier.handle(url: URL(string: "folobutton-dev://agent?event=clear")!)
        XCTAssertNil(notifier.current)
        XCTAssertFalse(notifier.handle(url: URL(string: "vibekey://agent?event=done")!))
        XCTAssertFalse(notifier.handle(url: URL(string: "https://example.com")!))
    }

    // MARK: Agent hook 配置(链:AgentHookRow.install → AgentHookInstaller.install)

    func testHookInstallMergesAndIsIdempotent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        // 已有配置:别的 hook 和其他设置都要保留。
        let original = Data(#"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"vibekey://agent?event=done"}]}]}}"#.utf8)
        try original.write(to: file)
        XCTAssertFalse(AgentHookInstaller.isInstalled(.codex, at: file))
        try AgentHookInstaller.install(.codex, at: file)
        try AgentHookInstaller.install(.codex, at: file)
        XCTAssertTrue(AgentHookInstaller.isInstalled(.codex, at: file))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "x")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["Stop"] as? [Any])?.count, 2, "保留原 hook,追加一条且不重复")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("vibekey://agent?event=done"))
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("folobutton-dev.bak").path))
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("folobutton-dev.bak")), original,
                       "重复安装不能覆盖首次备份")
        try? FileManager.default.removeItem(at: file.appendingPathExtension("folobutton-dev.bak"))
    }

    func testHookCommandsPerAgent() {
        XCTAssertEqual(AgentHookInstaller.command(.done, agent: .claudeCode), "open -g 'folobutton-dev://agent?event=done&source=Claude%20Code'")
        XCTAssertEqual(AgentHookInstaller.Agent.codex.events.map(\.hook), ["Stop", "PermissionRequest", "UserPromptSubmit"])
    }

    @MainActor
    func testCodexCompletionKeepsTheDisplayedChatWhenAnotherFinishes() throws {
        let notifier = AgentNotifier()
        let a = UUID(), b = UUID()
        func completion(_ thread: UUID) throws -> URL {
            try XCTUnwrap(URL(string: "folobutton-dev://agent?event=done&source=Codex&thread=\(thread)&turn=1"))
        }
        XCTAssertTrue(notifier.handle(url: try completion(a)))
        XCTAssertTrue(notifier.handle(url: try completion(b)))
        XCTAssertTrue(notifier.handle(url: try completion(a)))
        notifier.post(.clear, source: "Codex")
        XCTAssertEqual(notifier.current?.threadID, a)
        notifier.pauseCompletedNotices()
        notifier.dismiss(fromDevice: true)
        XCTAssertNil(notifier.current, "续聊过程中不能弹出下一张卡并吞掉录音键")
        notifier.resumeCompletedNotices()
        XCTAssertEqual(notifier.current?.threadID, b)
        notifier.dismiss()
        XCTAssertNil(notifier.current, "同一轮 Stop 的重复通知只显示一次")
    }

    @MainActor
    func testCodexCompletionResumesWhenFollowupDraftIsNotSent() async throws {
        let notifier = AgentNotifier()
        let thread = UUID()
        let url = try XCTUnwrap(URL(string: "folobutton-dev://agent?event=done&source=Codex&thread=\(thread)"))
        notifier.pauseCompletedNotices(for: .milliseconds(20))
        XCTAssertTrue(notifier.handle(url: url))
        XCTAssertNil(notifier.current)
        let deadline = ContinuousClock.now + .seconds(1)
        while notifier.current == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(notifier.current?.threadID, thread)
        notifier.dismiss()
    }

    func testFollowupAcceptsOnlyCanonicalLocalChatLinks() {
        let thread = UUID()
        let link = CodexThreadNavigator.link(to: thread).absoluteString
        XCTAssertEqual(CodexThreadNavigator.threadID(from: link), thread)
        XCTAssertNil(CodexThreadNavigator.threadID(from: "codex://threads/new"))
        XCTAssertNil(CodexThreadNavigator.threadID(from: link + "?prompt=test"))
        XCTAssertNil(CodexThreadNavigator.threadID(from: link.replacingOccurrences(of: "codex://", with: "https://")))
    }

    func testLegacyCodexStopHookUpgradesInPlace() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("folobutton-dev.bak"))
        }
        let original = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"open -g 'folobutton-dev://agent?event=done&source=Codex'"},{"type":"command","command":"other-hook"}]}]}}"#.utf8)
        try original.write(to: file)
        XCTAssertFalse(AgentHookInstaller.isInstalled(.codex, at: file))
        try AgentHookInstaller.install(.codex, at: file)
        try AgentHookInstaller.install(.codex, at: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let groups = (root["hooks"] as? [String: [[String: Any]]])?["Stop"]
        XCTAssertEqual(groups?.count, 1)
        let entries = groups?.first?["hooks"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?.first?["command"] as? String, AgentHookInstaller.command(.done, agent: .codex))
        XCTAssertEqual(entries?.last?["command"] as? String, "other-hook")
    }

}

nonisolated final class NormalizeTests: XCTestCase {
    func testRemovesSpacesAroundCJK() {
        XCTAssertEqual(TranscriptText.normalize("拆成两个小函数 ，然后 补充测试"), "拆成两个小函数，然后补充测试")
    }

    func testKeepsLatinSpaces() {
        XCTAssertEqual(TranscriptText.normalize(" open the SwiftUI docs "), "open the SwiftUI docs")
    }
}

nonisolated final class PunctuationTests: XCTestCase {
    func testHalfWidthAfterCJKBecomesFullWidth() {
        XCTAssertEqual(TranscriptText.normalize("重构一下,拆成两个函数。最后提交?"), "重构一下，拆成两个函数。最后提交？")
    }

    func testLatinPunctuationUntouched() {
        XCTAssertEqual(TranscriptText.normalize("Version 3.14, ok."), "Version 3.14, ok.")
    }
}
