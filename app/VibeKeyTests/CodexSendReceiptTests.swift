import XCTest
import Carbon.HIToolbox
@testable import VibeKey

/// 只比较回执证据，不操作真实桌面或向当前聊天提交文字。
nonisolated final class CodexSendReceiptTests: XCTestCase {
    private func target(process: Int32 = 10, window: String = "window", chat: String = "chat", input: String = "input") -> CodexDraftTarget {
        .init(processID: process, windowID: window, conversationID: chat, inputID: input)!
    }

    private func snapshot(_ target: CodexDraftTarget, text: String = "", running: Bool = false,
                          frontmost: Bool = true, unlocked: Bool = true, pending: Bool = false) -> CodexTargetSnapshot {
        .init(target: target, isFrontmost: frontmost, isUnlocked: unlocked, inputText: text,
              runState: running ? .running : .idle, hasPendingApproval: pending)
    }

    func testComposerRecreationInSameConversationCanConfirm() {
        let before = target()
        XCTAssertTrue(CodexSendReceipt.confirms(snapshot(target(input: "new-input"), running: true), target: before))
        // 很快完成的任务也会清空输入框，不强制要求恰好观测到 running。
        XCTAssertTrue(CodexSendReceipt.confirms(snapshot(target(input: "new-input")), target: before))
    }

    func testTextChangeOrRunningAloneDoesNotConfirmSubmission() {
        XCTAssertFalse(CodexSendReceipt.confirms(snapshot(target(), text: "unchanged", running: true), target: target()))
        XCTAssertFalse(CodexSendReceipt.confirms(snapshot(target(), text: "edited draft"), target: target()))
    }

    func testDifferentChatWindowOrProcessCannotSupplyReceipt() {
        for changed in [target(chat: "other"), target(window: "other"), target(process: 11)] {
            XCTAssertFalse(CodexSendReceipt.confirms(snapshot(changed, running: true), target: target()))
        }
    }

    func testBackgroundLockedOrApprovalStateCannotSupplyReceipt() {
        for after in [snapshot(target(), frontmost: false), snapshot(target(), unlocked: false), snapshot(target(), pending: true)] {
            XCTAssertFalse(CodexSendReceipt.confirms(after, target: target()))
        }
    }

    @MainActor func testProcessBoundReturnIsDisabledInTestHost() {
        XCTAssertFalse(KeySender.press(kVK_Return, flags: .maskCommand, processID: 10))
    }
}
