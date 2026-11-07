import Foundation
import XCTest
@testable import VibeKey

/// 验证草稿目标、期限与一次性发送租约,不触发真实键盘或桌面应用。
nonisolated final class CodexDraftBufferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func target(_ chat: String = "chat-a") -> CodexDraftTarget {
        CodexDraftTarget(processID: 10, windowID: "window", conversationID: chat, inputID: "input")!
    }

    func testRejectsUnknownTargetAndKeepsDraftWhenChatChanges() {
        XCTAssertNil(CodexDraftTarget(processID: 10, windowID: "", conversationID: "chat", inputID: "input"))
        var buffer = CodexDraftBuffer()
        XCTAssertEqual(buffer.append("hello", target: target(), expiresAt: now.addingTimeInterval(60), now: now), .accepted)
        XCTAssertEqual(buffer.append("wrong chat", target: target("chat-b"), expiresAt: now.addingTimeInterval(60), now: now), .targetChanged)
        XCTAssertEqual(buffer.beginSend(to: target("chat-b"), now: now).0, .targetChanged)
        XCTAssertEqual(buffer.draft?.text, "hello")
    }

    func testAppendDoesNotExtendExpiry() {
        var buffer = CodexDraftBuffer()
        XCTAssertEqual(buffer.append("first", target: target(), expiresAt: now.addingTimeInterval(10), now: now), .accepted)
        XCTAssertEqual(buffer.append("second", target: target(), expiresAt: now.addingTimeInterval(100), now: now), .accepted)
        XCTAssertEqual(buffer.draft?.text, "first\nsecond")
        XCTAssertEqual(buffer.beginSend(to: target(), now: now.addingTimeInterval(10)).0, .expired)
    }

    func testUnknownDeliveryBlocksRetryUntilDiscarded() {
        var buffer = CodexDraftBuffer()
        _ = buffer.append("hello", target: target(), expiresAt: now.addingTimeInterval(60), now: now)
        let lease = buffer.beginSend(to: target(), now: now).1!
        XCTAssertEqual(buffer.discard(), .busy)
        XCTAssertEqual(buffer.finish(lease.id, delivery: .unknown), .accepted)
        XCTAssertEqual(buffer.beginSend(to: target(), now: now).0, .uncertain)
        XCTAssertEqual(buffer.draft?.text, "hello")
        XCTAssertEqual(buffer.discard(), .accepted)
        XCTAssertEqual(buffer.beginSend(to: target(), now: now).0, .noDraft)
    }

    func testOldReceiptCannotConsumeNewAttempt() {
        var buffer = CodexDraftBuffer()
        _ = buffer.append("hello", target: target(), expiresAt: now.addingTimeInterval(60), now: now)
        let first = buffer.beginSend(to: target(), now: now).1!
        XCTAssertEqual(buffer.finish(first.id, delivery: .notSent), .accepted)
        let second = buffer.beginSend(to: target(), now: now).1!
        XCTAssertEqual(buffer.finish(first.id, delivery: .confirmed), .staleAttempt)
        XCTAssertEqual(buffer.draft?.text, "hello")
        XCTAssertEqual(buffer.finish(second.id, delivery: .confirmed), .accepted)
        XCTAssertNil(buffer.draft)
    }
}
