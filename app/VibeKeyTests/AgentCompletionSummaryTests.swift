import XCTest
@testable import VibeKey

nonisolated final class AgentCompletionSummaryTests: XCTestCase {
    func testPagesKeepAllChineseAndRespectWireLimits() {
        let text = String(repeating: "任务已完成请检查结果并确认下一步。", count: 24)
        let pages = AgentCompletionSummary.pages(text)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.flatMap { $0 }.joined(), text)
        for page in pages {
            XCTAssertLessThanOrEqual(page.count, HostCommand.listVisibleRows)
            XCTAssertTrue(page.allSatisfy { $0.utf8.count <= HostCommand.listTextMaxBytes })
            let command = HostCommand.list(title: "RESULT 1/2", sel: 0, total: page.count, top: 0, items: page)
            XCTAssertLessThanOrEqual(command.line.utf8.count, 511)
        }
    }

    func testFallbackPreservesBeginningAndNextStep() {
        let source = "未完成：需要用户确认。" + String(repeating: "过程细节", count: 200) + "下一步请授权。"
        let result = AgentCompletionSummary.fallback(source)
        XCTAssertTrue(result.contains("未完成"))
        XCTAssertTrue(result.contains("下一步请授权"))
        XCTAssertLessThanOrEqual(result.count, 363)
    }

    func testFallbackHighlightsBlockingIssueAndNextStepInLongReply() {
        let source = "功能已经修改。\n" + String(repeating: "实现细节和背景说明。", count: 80)
            + "\n但是测试失败，当前结果未验证。\n下一步请先授权并重新运行测试。\n"
            + String(repeating: "其他说明。", count: 80) + "\n可以查看文档。"
        let result = AgentCompletionSummary.fallback(source)
        XCTAssertTrue(result.contains("功能已经修改"))
        XCTAssertTrue(result.contains("测试失败"))
        XCTAssertTrue(result.contains("下一步请先授权"))
        XCTAssertLessThanOrEqual(result.count, 360)
    }

    func testLocalAgentLogParsersExtractOnlyCompletedFinalReplies() throws {
        let thread = UUID()
        let codex = try XCTUnwrap(AgentCompletionLogParser.codex([
            "type": "event_msg",
            "timestamp": "2026-11-16T10:18:52.818Z",
            "payload": [
                "type": "task_complete",
                "turn_id": "turn-7",
                "last_agent_message": "修改完成，下一步请检查测试。",
            ],
        ], fileURL: URL(fileURLWithPath: "/tmp/rollout-\(thread.uuidString).jsonl"), project: "demo"))
        XCTAssertEqual(codex.event.source, "Codex")
        XCTAssertEqual(codex.event.threadID, thread)
        XCTAssertEqual(codex.event.reply, "修改完成，下一步请检查测试。")

        let claude = try XCTUnwrap(AgentCompletionLogParser.claudeCode([
            "type": "assistant",
            "sessionId": "claude-session",
            "uuid": "message-1",
            "cwd": "/tmp/demo",
            "timestamp": "2026-11-16T10:18:52.818Z",
            "message": [
                "role": "assistant",
                "stop_reason": "end_turn",
                "content": [["type": "text", "text": "Claude 已完成。"]],
            ],
        ], fileURL: URL(fileURLWithPath: "/tmp/claude-session.jsonl")))
        XCTAssertEqual(claude.event.source, "Claude Code")
        XCTAssertEqual(claude.event.reply, "Claude 已完成。")

        let deepSeek = try XCTUnwrap(AgentCompletionLogParser.deepSeek([
            "record": [
                "identity": ["cwd": "/tmp/demo"],
                "rows": [
                    "sessionStats": ["val": ["openStep": NSNull(), "pendingCalls": [:]]],
                    "turnOutline": ["val": ["turns": [
                        ["turn": 1, "response": "中间结果"],
                        ["turn": 2, "response": "DeepSeek 已完成。"],
                    ]]],
                ],
            ],
        ], fileURL: URL(fileURLWithPath: "/tmp/session-\(UUID().uuidString).json")))
        XCTAssertEqual(deepSeek.event.source, "DeepSeek")
        XCTAssertEqual(deepSeek.event.reply, "DeepSeek 已完成。")

        let zcode = try XCTUnwrap(AgentCompletionLogParser.zcode([
            "type": "model_io",
            "sessionId": "z-session",
            "turnId": "z-turn",
            "requestId": "z-response",
            "completedAt": "2026-11-16T10:18:52.818Z",
            "response": ["finishReason": "stop", "text": "ZCode 已完成。"],
        ]))
        XCTAssertEqual(zcode.event.source, "ZCode")
        XCTAssertEqual(zcode.event.reply, "ZCode 已完成。")

        let workBuddy = try XCTUnwrap(AgentCompletionLogParser.workBuddy([
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "sessionId": "wb-session",
            "id": "wb-message",
            "cwd": "/tmp/demo",
            "timestamp": "2026-11-16T10:18:52.818Z",
            "content": [["type": "text", "text": "WorkBuddy 已完成。"]],
        ], fileURL: URL(fileURLWithPath: "/tmp/wb-session.jsonl")))
        XCTAssertEqual(workBuddy.event.source, "WorkBuddy")
        XCTAssertEqual(workBuddy.event.reply, "WorkBuddy 已完成。")
    }

    @MainActor func testLocalAndHookCompletionDoNotDuplicate() {
        let notifier = AgentNotifier()
        let event = AgentCompletionEvent(
            source: "Claude Code", reply: "任务已经完成。", project: nil,
            threadID: nil, turnID: "turn", deduplicationKey: "claude:test"
        )
        notifier.postCompletion(event)
        notifier.postCompletion(event)
        XCTAssertEqual(notifier.current?.summary, "任务已经完成。")
        notifier.dismiss()
        XCTAssertNil(notifier.current)
    }

    func testPrivateInboxConsumesOnceAndRejectsInvalidFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID().uuidString
        let file = dir.appendingPathComponent(id + ".json")
        let payload = try JSONSerialization.data(withJSONObject: ["last_assistant_message": "失败，需要重新登录。"])
        try payload.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(AgentCompletionInbox.consume(id, directory: dir), "失败，需要重新登录。")
        XCTAssertNil(AgentCompletionInbox.consume(id, directory: dir))
        XCTAssertNil(AgentCompletionInbox.consume("../other", directory: dir))
        try payload.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertNil(AgentCompletionInbox.consume(id, directory: dir))
    }

    func testActualCodexHookTransfersReplyWithoutPuttingItInURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urlFile = root.appendingPathComponent("url.txt")
        let thread = UUID().uuidString
        let reply = "任务没有完成，请先授权。"
        let payload = try JSONSerialization.data(withJSONObject: ["session_id": thread, "turn_id": "turn-1", "cwd": "/tmp/project", "last_assistant_message": reply])
        let command = AgentHookInstaller.command(.done, agent: .codex)
            .replacingOccurrences(of: "dir=\"$HOME/Library/Caches/FoloVibeKey/AgentInbox\"", with: "dir=\"\(inbox.path)\"")
            .replacingOccurrences(of: "/usr/bin/open -g -b local.folobutton.dev", with: "/usr/bin/printf '%s'")
            .replacingOccurrences(of: ">/dev/null 2>&1", with: ">\"\(urlFile.path)\" 2>&1")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let url = try XCTUnwrap(URL(string: String(contentsOf: urlFile, encoding: .utf8)))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertFalse(url.absoluteString.contains(reply))
        XCTAssertEqual(items.first(where: { $0.name == "thread" })?.value, thread)
        XCTAssertEqual(items.first(where: { $0.name == "turn" })?.value, "turn-1")
        XCTAssertEqual(items.first(where: { $0.name == "project" })?.value, "project")
        let token = try XCTUnwrap(items.first(where: { $0.name == "payload" })?.value)
        XCTAssertEqual(AgentCompletionInbox.consume(token, directory: inbox), reply)
    }

    @MainActor func testCompletionNoticeKeepsItsReplyAndQueuesNextThread() throws {
        let dir = AgentCompletionInbox.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func completion(_ text: String, thread: UUID) throws -> URL {
            let id = UUID().uuidString
            let file = dir.appendingPathComponent(id + ".json")
            try JSONSerialization.data(withJSONObject: ["last_assistant_message": text]).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return try XCTUnwrap(URL(string: "folobutton-dev://agent?event=done&source=Codex&payload=\(id)&thread=\(thread)&turn=1"))
        }
        let a = UUID(), b = UUID()
        let notifier = AgentNotifier()
        var queuedAlerts = 0
        notifier.onQueuedCompletion = { _ in queuedAlerts += 1 }
        XCTAssertTrue(notifier.handle(url: try completion("第一项失败，请重试。", thread: a)))
        XCTAssertTrue(notifier.handle(url: try completion("第二项已经完成。", thread: b)))
        XCTAssertEqual(queuedAlerts, 1)
        XCTAssertEqual(notifier.current?.threadID, a)
        XCTAssertEqual(notifier.current?.summary, "第一项失败，请重试。")
        notifier.dismiss()
        XCTAssertEqual(notifier.current?.threadID, b)
        XCTAssertEqual(notifier.current?.summary, "第二项已经完成。")
        notifier.dismiss()
    }
}
