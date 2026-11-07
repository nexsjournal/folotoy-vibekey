import Foundation
import XCTest
@testable import VibeKey

/// 从目标检查到发送回执逐环测试;适配器替身不会操作当前桌面。
nonisolated final class CodexActionCoordinatorTests: XCTestCase {
    @MainActor private final class Adapter: CodexDesktopAdapter {
        var snapshot: CodexTargetSnapshot?
        var delivery: CodexDraftBuffer.Delivery = .confirmed
        var fail = false
        var sent: [String] = []
        var stopCount = 0
        var onInspect: (() -> Void)?
        var suspendInspection = false
        var inspectionContinuation: CheckedContinuation<Void, Never>?
        var queuedSnapshots: [CodexTargetSnapshot?] = []
        var inspectionError: Error?
        func inspectTarget() async throws -> CodexTargetSnapshot? {
            onInspect?()
            if suspendInspection { await withCheckedContinuation { inspectionContinuation = $0 } }
            if let inspectionError { throw inspectionError }
            if !queuedSnapshots.isEmpty { return queuedSnapshots.removeFirst() }
            return snapshot
        }
        func send(_ attempt: CodexDraftBuffer.Attempt, using snapshot: CodexTargetSnapshot) async throws -> CodexDraftBuffer.Delivery {
            sent.append(attempt.draft.text)
            if fail { throw CancellationError() }
            return delivery
        }
        func stop(using snapshot: CodexTargetSnapshot) async throws -> CodexDraftBuffer.Delivery {
            stopCount += 1
            if fail { throw CancellationError() }
            return delivery
        }
    }

    private func target(_ chat: String = "a") -> CodexDraftTarget {
        CodexDraftTarget(processID: 10, windowID: "w", conversationID: chat, inputID: "i")!
    }

    private func snapshot(_ target: CodexDraftTarget, input: String = "", pending: Bool = false,
                          idle: Bool = true, frontmost: Bool = true, unlocked: Bool = true, canSend: Bool = true) -> CodexTargetSnapshot {
        .init(target: target, isFrontmost: frontmost, isUnlocked: unlocked, inputText: input,
              runState: idle ? .idle : .running, hasPendingApproval: pending, canSend: canSend)
    }

    @MainActor func testChangedTargetOrUnsafeStateNeverDispatches() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        coordinator.append("hello", target: t, expiresAt: Date().addingTimeInterval(60))
        for s in [snapshot(target("b")), snapshot(t, input: "other"), snapshot(t, pending: true),
                  snapshot(t, idle: false, canSend: false), snapshot(t, frontmost: false), snapshot(t, unlocked: false)] {
            adapter.snapshot = s
            await coordinator.send()
            XCTAssertTrue(adapter.sent.isEmpty)
            XCTAssertEqual(coordinator.buffer.draft?.text, "hello")
        }
    }

    @MainActor func testConfirmedSendConsumesDraft() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        adapter.snapshot = snapshot(t, input: "hello")
        coordinator.append("hello", target: t, expiresAt: Date().addingTimeInterval(60))
        await coordinator.send()
        XCTAssertEqual(adapter.sent, ["hello"])
        XCTAssertEqual(coordinator.outcome, .accepted)
        XCTAssertNil(coordinator.buffer.draft)
    }

    @MainActor func testThrownSendLocksRetryWithoutLosingDraft() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        adapter.snapshot = snapshot(t, input: "hello")
        adapter.fail = true
        coordinator.append("hello", target: t, expiresAt: Date().addingTimeInterval(60))
        await coordinator.send()
        XCTAssertEqual(coordinator.outcome, .uncertain)
        await coordinator.send()
        XCTAssertEqual(adapter.sent, ["hello"])
        XCTAssertEqual(coordinator.buffer.draft?.text, "hello")
    }

    @MainActor func testExpiryIsRecheckedAfterInspectingTarget() async {
        let adapter = Adapter()
        let t = target()
        var now = Date(timeIntervalSince1970: 1000)
        let coordinator = CodexActionCoordinator(adapter: adapter, clock: { now })
        adapter.snapshot = snapshot(t, input: "hello")
        adapter.onInspect = { now = now.addingTimeInterval(11) }
        coordinator.append("hello", target: t, expiresAt: now.addingTimeInterval(10), now: now)
        await coordinator.send()
        XCTAssertEqual(coordinator.outcome, .expired)
        XCTAssertTrue(adapter.sent.isEmpty)
    }

    @MainActor func testDraftReplacedDuringInspectionIsNotSent() async {
        let adapter = Adapter()
        let t = target()
        let expiration = Date().addingTimeInterval(60)
        let coordinator = CodexActionCoordinator(adapter: adapter)
        coordinator.append("hello", target: t, expiresAt: expiration)
        adapter.snapshot = snapshot(t, input: "hello")
        adapter.onInspect = {
            coordinator.discard()
            coordinator.append("hello", target: t, expiresAt: expiration)
        }
        await coordinator.send()
        XCTAssertEqual(coordinator.outcome, .checkMac)
        XCTAssertTrue(adapter.sent.isEmpty)
        XCTAssertEqual(coordinator.buffer.draft?.text, "hello")
    }

    @MainActor func testStopRequiresSameRunningChatAndNoApproval() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        for s in [snapshot(target("b"), idle: false), snapshot(t), snapshot(t, pending: true, idle: false),
                  snapshot(t, idle: false, unlocked: false)] {
            adapter.snapshot = s
            await coordinator.stop(target: t)
            XCTAssertEqual(adapter.stopCount, 0)
        }
        adapter.snapshot = snapshot(t, idle: false)
        await coordinator.stop(target: t)
        XCTAssertEqual(adapter.stopCount, 1)
        XCTAssertEqual(coordinator.outcome, .stopped)
    }

    @MainActor func testUncertainStopCannotRepeatUntilAcknowledged() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        adapter.snapshot = snapshot(t, idle: false)
        adapter.fail = true
        await coordinator.stop(target: t)
        await coordinator.stop(target: t)
        XCTAssertEqual(coordinator.outcome, .uncertain)
        XCTAssertEqual(adapter.stopCount, 1)
        coordinator.acknowledgeUncertainStop(target: t)
        adapter.fail = false
        await coordinator.stop(target: t)
        XCTAssertEqual(adapter.stopCount, 2)
        XCTAssertEqual(coordinator.outcome, .stopped)
    }

    @MainActor func testUncertainStopsRemainBoundToEachChat() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let a = target(), b = target("b")
        adapter.fail = true
        adapter.snapshot = snapshot(a, idle: false)
        await coordinator.stop(target: a)
        adapter.snapshot = snapshot(b, idle: false)
        await coordinator.stop(target: b)
        coordinator.acknowledgeUncertainStop(target: a)
        await coordinator.stop(target: b)
        XCTAssertEqual(coordinator.outcome, .uncertain)
        XCTAssertEqual(adapter.stopCount, 2)
    }

    @MainActor func testStopCannotRacePendingSendInspection() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        coordinator.append("hello", target: t, expiresAt: Date().addingTimeInterval(60))
        adapter.snapshot = snapshot(t, input: "hello")
        adapter.suspendInspection = true
        let sendTask = Task { await coordinator.send() }
        for _ in 0..<1000 {
            if adapter.inspectionContinuation != nil { break }
            await Task.yield()
        }
        guard let continuation = adapter.inspectionContinuation else {
            sendTask.cancel()
            return XCTFail("发送没有进入目标检查")
        }
        await coordinator.stop(target: t)
        XCTAssertEqual(coordinator.outcome, .busy)
        XCTAssertEqual(adapter.stopCount, 0)
        continuation.resume()
        await sendTask.value
        XCTAssertEqual(adapter.sent, ["hello"])
    }

    @MainActor func testCaptureRequiresEmptyIdleComposer() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        adapter.snapshot = snapshot(t, input: "existing")
        let existingTarget = await coordinator.captureTarget()
        XCTAssertNil(existingTarget)
        XCTAssertEqual(coordinator.captureFailure, .inputNotEmpty)
        adapter.snapshot = snapshot(t, idle: false)
        let runningTarget = await coordinator.captureTarget()
        XCTAssertNil(runningTarget)
        XCTAssertEqual(coordinator.captureFailure, .running)
        adapter.snapshot = snapshot(t)
        let captured = await coordinator.captureTarget()
        XCTAssertEqual(captured, t)
        XCTAssertNil(coordinator.captureFailure)
    }

    @MainActor func testCaptureRetriesTransientAXUnavailability() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        adapter.queuedSnapshots = [nil, nil, snapshot(t)]
        let captured = await coordinator.captureTarget()
        XCTAssertEqual(captured, t)
        XCTAssertEqual(coordinator.outcome, .ready)
    }

    @MainActor func testCaptureReportsPermissionAndMissingAppSeparately() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.inspectionError = CodexDesktopAdapterError.accessibilityDenied
        let permissionTarget = await coordinator.captureTarget()
        XCTAssertNil(permissionTarget)
        XCTAssertEqual(coordinator.captureFailure, .accessibilityDenied)

        adapter.inspectionError = CodexDesktopAdapterError.appUnavailable
        let missingTarget = await coordinator.captureTarget()
        XCTAssertNil(missingTarget)
        XCTAssertEqual(coordinator.captureFailure, .notRunning)
    }

    @MainActor func testDraftValidationBindsTheSameEmptyComposer() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        let t = target()
        adapter.snapshot = snapshot(t)
        let valid = await coordinator.validateForDraft(t)
        XCTAssertTrue(valid)
        adapter.snapshot = snapshot(target("b"))
        let changed = await coordinator.validateForDraft(t)
        XCTAssertFalse(changed)
    }

    @MainActor func testPastedDraftMustAppearInSameComposer() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(
            adapter: adapter, pasteVerificationTimeout: .milliseconds(120)
        )
        let t = target()
        adapter.snapshot = snapshot(t, input: "")
        let missing = await coordinator.validatePastedDraft(t, text: "hello")
        XCTAssertFalse(missing)
        XCTAssertEqual(coordinator.outcome, .checkMac)

        adapter.snapshot = snapshot(t, input: "hello")
        let appeared = await coordinator.validatePastedDraft(t, text: "hello")
        XCTAssertTrue(appeared)
        XCTAssertEqual(coordinator.outcome, .ready)

        adapter.snapshot = snapshot(target("b"), input: "hello")
        let changed = await coordinator.validatePastedDraft(t, text: "hello")
        XCTAssertFalse(changed)
        XCTAssertEqual(coordinator.outcome, .targetChanged)
    }

    @MainActor func testCurrentStopUsesFrontmostRunningChat() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target(), idle: false)
        await coordinator.stopCurrent()
        XCTAssertEqual(adapter.stopCount, 1)
        XCTAssertEqual(coordinator.outcome, .stopped)
    }

    @MainActor func testKnownIdleChatReportsNoTaskWithoutDispatch() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target())
        await coordinator.stopCurrent()
        XCTAssertEqual(coordinator.outcome, .noTask)
        XCTAssertEqual(adapter.stopCount, 0)
    }

    @MainActor func testSendingWithoutDraftReportsNoDraft() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target())
        await coordinator.send()
        XCTAssertEqual(coordinator.outcome, .noDraft)
        XCTAssertTrue(adapter.sent.isEmpty)
    }

    @MainActor func testExplicitSendAdoptsManualComposerDraft() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target(), input: "manual draft")
        await coordinator.send()
        XCTAssertEqual(adapter.sent, ["manual draft"])
        XCTAssertEqual(coordinator.outcome, .accepted)
    }

    @MainActor func testManualDraftCannotFollowAChangedChat() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.queuedSnapshots = [snapshot(target(), input: "manual draft"), snapshot(target("b"), input: "manual draft")]
        await coordinator.send()
        XCTAssertTrue(adapter.sent.isEmpty)
        XCTAssertEqual(coordinator.outcome, .targetChanged)
    }

    /// 当前任务运行时，UI 允许提交就应接受后续消息；不能用 running 代替按钮可用性。
    @MainActor func testExplicitFollowupCanSubmitWhileTaskIsRunning() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target(), input: "followup", idle: false, canSend: true)
        await coordinator.send()
        XCTAssertEqual(adapter.sent, ["followup"])
        XCTAssertEqual(coordinator.outcome, .accepted)
    }

    @MainActor func testUnavailableSubmitControlNeverDispatchesWhileRunning() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target(), input: "followup", idle: false, canSend: false)
        await coordinator.send()
        XCTAssertTrue(adapter.sent.isEmpty)
        XCTAssertEqual(coordinator.outcome, .busy)
    }

    @MainActor func testThreeConsecutiveComposerDraftsSendIndependently() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        for text in ["first", "second", "third"] {
            adapter.snapshot = snapshot(target(), input: text)
            await coordinator.send()
            XCTAssertEqual(coordinator.outcome, .accepted)
            XCTAssertNil(coordinator.buffer.draft)
            XCTAssertFalse(coordinator.buffer.requiresReview)
        }
        XCTAssertEqual(adapter.sent, ["first", "second", "third"])
    }

    @MainActor func testNewEmptyDictationRecoversOldUnknownWithoutResendingIt() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target(), input: "old draft")
        adapter.delivery = .unknown
        await coordinator.send()
        XCTAssertTrue(coordinator.buffer.requiresReview)
        // 已发送或被用户清空后开始新录音；不据此声称旧消息已发送，也不补发它。
        adapter.snapshot = snapshot(target())
        await coordinator.prepareNewDictation()
        XCTAssertNil(coordinator.buffer.draft)
        XCTAssertFalse(coordinator.buffer.requiresReview)
        adapter.snapshot = snapshot(target(), input: "new draft")
        adapter.delivery = .confirmed
        await coordinator.send()
        XCTAssertEqual(coordinator.outcome, .accepted)
        XCTAssertEqual(adapter.sent, ["old draft", "new draft"])
    }

    @MainActor func testStartingAnotherRecordingCannotUnlockUnchangedOrEditedNonemptyDraft() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target(), input: "old draft")
        adapter.delivery = .unknown
        await coordinator.send()
        for text in ["old draft", "old draft plus more speech"] {
            adapter.snapshot = snapshot(target(), input: text)
            await coordinator.prepareNewDictation()
            await coordinator.send()
            XCTAssertTrue(coordinator.buffer.requiresReview)
            XCTAssertEqual(coordinator.outcome, .uncertain)
        }
        XCTAssertEqual(adapter.sent, ["old draft"])
    }

    @MainActor func testUnsafeEmptyComposerCannotClearSendReview() async {
        let adapter = Adapter()
        let coordinator = CodexActionCoordinator(adapter: adapter)
        adapter.snapshot = snapshot(target(), input: "draft")
        adapter.delivery = .unknown
        await coordinator.send()
        for current in [snapshot(target(), pending: true), snapshot(target(), frontmost: false),
                        snapshot(target(), unlocked: false)] {
            adapter.snapshot = current
            await coordinator.prepareNewDictation()
            XCTAssertTrue(coordinator.buffer.requiresReview)
        }
    }

    func testComposerComparisonNormalizesWhitespaceOnly() {
        XCTAssertTrue(CodexActionCoordinator.inputMatches("hello\nworld", " hello world "))
        XCTAssertFalse(CodexActionCoordinator.inputMatches("hello world", "hello other"))
    }
}
