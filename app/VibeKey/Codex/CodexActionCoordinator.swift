import Foundation

/// 桌面侧重新读取的状态。未知状态不能表示为安全:适配器无法确认时必须返回 nil。
nonisolated struct CodexTargetSnapshot: Equatable, Sendable {
    enum RunState: Equatable, Sendable { case idle, running }
    enum ConversationIdentity: String, Equatable, Sendable { case document, url, identifier, title }
    let target: CodexDraftTarget
    let isFrontmost: Bool
    let isUnlocked: Bool
    /// 当前输入框全文。调用方只为核对目标绑定，不得写日志或持久化。
    let inputText: String
    let runState: RunState
    let hasPendingApproval: Bool
    /// 当前编辑器的发送控件是否可用；任务运行中仍可能支持排队，不用 running 推断发送能力。
    let canSend: Bool
    /// Codex 聊天是否有独立 AX 文档标识；仅用于脱敏诊断和后续绑定策略，不记录标识本身。
    let conversationIdentity: ConversationIdentity

    init(
        target: CodexDraftTarget,
        isFrontmost: Bool,
        isUnlocked: Bool,
        inputText: String,
        runState: RunState,
        hasPendingApproval: Bool,
        conversationIdentity: ConversationIdentity = .title,
        canSend: Bool = true
    ) {
        self.target = target
        self.isFrontmost = isFrontmost
        self.isUnlocked = isUnlocked
        self.inputText = inputText
        self.runState = runState
        self.hasPendingApproval = hasPendingApproval
        self.conversationIdentity = conversationIdentity
        self.canSend = canSend
    }

    var inputIsEmpty: Bool { inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

nonisolated enum CodexDesktopAdapterError: Error {
    case accessibilityDenied
    case appUnavailable
}

/// 桌面适配器必须在真正输入前再次核对快照和租约有效期,不得只依赖调用者之前的检查。
/// 未能证明新消息已提交时返回 unknown;只有确定没有执行发送才能返回 notSent。
@MainActor protocol CodexDesktopAdapter: AnyObject {
    func inspectTarget() async throws -> CodexTargetSnapshot?
    func send(_ attempt: CodexDraftBuffer.Attempt, using snapshot: CodexTargetSnapshot) async throws -> CodexDraftBuffer.Delivery
    /// 仅作用于给定快照中的聊天,并在触发前再次核对目标与运行状态。
    func stop(using snapshot: CodexTargetSnapshot) async throws -> CodexDraftBuffer.Delivery
}

/// 专用控制链的草稿与发送编排。该模块不读取 UI、不模拟按键;调用者在主线程使用。
@MainActor @Observable
final class CodexActionCoordinator {
    enum Outcome: Equatable {
        case ready, accepted, stopped, noDraft, noTask, expired, targetChanged, checkMac, busy, uncertain
    }
    enum CaptureFailure: Equatable {
        case unavailable, accessibilityDenied, notRunning, background, locked, inputNotEmpty, running, approvalPending
    }

    private(set) var buffer = CodexDraftBuffer()
    private(set) var outcome: Outcome = .ready
    private(set) var captureFailure: CaptureFailure?
    @ObservationIgnored private let adapter: CodexDesktopAdapter
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let pasteVerificationTimeout: Duration
    private var sendInFlight = false
    private var stopInFlight = false
    /// 中断结果不明时,不对同一目标盲目重试。
    private var uncertainStops: Set<CodexDraftTarget> = []

    init(
        adapter: CodexDesktopAdapter,
        clock: @escaping () -> Date = Date.init,
        pasteVerificationTimeout: Duration = .milliseconds(1_500)
    ) {
        self.adapter = adapter
        self.clock = clock
        self.pasteVerificationTimeout = pasteVerificationTimeout
    }

    /// 录音前确认目标,供本次录音结束后绑定;无法确定时不开始 Codex 专用输入。
    func captureTarget() async -> CodexDraftTarget? {
        // Codex 刚激活或更新界面时 AXWindows 可能短暂为空；最多重试 400 ms，仍不可用才失败。
        // 一旦读到明确的不安全状态（非空、运行中、审批、后台），立即停止重试。
        let deadline = ContinuousClock.now + .milliseconds(400)
        captureFailure = nil
        repeat {
            do {
                if let snapshot = try await adapter.inspectTarget() {
                    guard snapshot.isFrontmost else { captureFailure = .background; outcome = .checkMac; return nil }
                    guard snapshot.isUnlocked else { captureFailure = .locked; outcome = .checkMac; return nil }
                    guard !snapshot.hasPendingApproval else {
                        captureFailure = .approvalPending
                        outcome = .checkMac
                        return nil
                    }
                    guard snapshot.runState == .idle else { captureFailure = .running; outcome = .checkMac; return nil }
                    guard snapshot.inputIsEmpty else { captureFailure = .inputNotEmpty; outcome = .checkMac; return nil }
                    return snapshot.target
                }
            } catch CodexDesktopAdapterError.accessibilityDenied {
                captureFailure = .accessibilityDenied
                outcome = .checkMac
                return nil
            } catch CodexDesktopAdapterError.appUnavailable {
                captureFailure = .notRunning
                outcome = .checkMac
                return nil
            } catch {
                // AX 树重建期间继续重试；异常不能作为可绑定目标的证据。
            }
            try? await Task.sleep(for: .milliseconds(60))
        } while ContinuousClock.now < deadline
        captureFailure = .unavailable
        outcome = .checkMac
        return nil
    }

    /// 粘贴前再次确认录音开始时绑定的同一个空输入框仍可用。
    func validateForDraft(_ target: CodexDraftTarget) async -> Bool {
        do {
            guard let snapshot = try await adapter.inspectTarget(), snapshot.target == target,
                  snapshot.isFrontmost, snapshot.isUnlocked, snapshot.inputIsEmpty,
                  snapshot.runState == .idle, !snapshot.hasPendingApproval else {
                outcome = .checkMac
                return false
            }
            outcome = .ready
            return true
        } catch {
            outcome = .checkMac
            return false
        }
    }

    /// `TextInserter` 发出 ⌘V 后立即返回；必须回读同一输入框，确认整段文字已经出现，
    /// 才能显示 DRAFT READY 并建立可发送草稿。窗口变化立即失败，短暂空值或部分粘贴则等到超时。
    func validatePastedDraft(_ target: CodexDraftTarget, text: String) async -> Bool {
        let deadline = ContinuousClock.now + pasteVerificationTimeout
        repeat {
            guard !Task.isCancelled else { outcome = .checkMac; return false }
            do {
                if let snapshot = try await adapter.inspectTarget() {
                    guard snapshot.target == target else { outcome = .targetChanged; return false }
                    guard snapshot.isFrontmost, snapshot.isUnlocked,
                          snapshot.runState == .idle, !snapshot.hasPendingApproval else {
                        outcome = .checkMac
                        return false
                    }
                    if Self.inputMatches(snapshot.inputText, text) {
                        outcome = .ready
                        return true
                    }
                }
            } catch {
                // 输入框更新时 AX 树可能短暂不可用；超时前继续读取，不据此报告成功。
            }
            try? await Task.sleep(for: .milliseconds(80))
        } while ContinuousClock.now < deadline
        outcome = .checkMac
        return false
    }

    /// 只接收与录音起点绑定的目标。空识别结果保留原草稿。
    func append(_ text: String, target: CodexDraftTarget, expiresAt: Date, now: Date = Date()) {
        outcome = Self.map(buffer.append(text, target: target, expiresAt: expiresAt, now: now))
    }

    /// 重新检查目标、焦点、锁屏、现有输入和待审批,然后取得一次性发送租约。
    func send(expectedTarget: CodexDraftTarget? = nil) async {
        guard !buffer.requiresReview else { outcome = .uncertain; return }
        guard !sendInFlight, !stopInFlight, buffer.attempt == nil else { outcome = .busy; return }
        sendInFlight = true
        defer { sendInFlight = false }
        // 上键表示发送当前可见输入框；手动输入与语音输入使用同一条目标核对和回执链。
        // 只在用户明确按上键时接纳外部草稿，不会后台自动发送。
        if buffer.draft == nil {
            do {
                guard let current = try await adapter.inspectTarget(), current.isFrontmost, current.isUnlocked,
                      !current.hasPendingApproval else { outcome = .checkMac; return }
                if let expectedTarget, current.target != expectedTarget { outcome = .targetChanged; return }
                guard !current.inputIsEmpty else { outcome = .noDraft; return }
                guard current.canSend else { outcome = .busy; return }
                let now = clock()
                _ = buffer.append(current.inputText, target: current.target, expiresAt: now.addingTimeInterval(60), now: now)
            } catch { outcome = .checkMac; return }
        }
        guard let expectedDraft = buffer.draft else { outcome = .noDraft; return }
        let snapshot: CodexTargetSnapshot
        do {
            guard let current = try await adapter.inspectTarget(), current.isFrontmost, current.isUnlocked,
                  Self.inputMatches(current.inputText, expectedDraft.text),
                  !current.hasPendingApproval else {
                outcome = .checkMac
                return
            }
            guard current.canSend else { outcome = .busy; return }
            if let expectedTarget, current.target != expectedTarget { outcome = .targetChanged; return }
            snapshot = current
        } catch {
            outcome = .checkMac
            return
        }
        guard !Task.isCancelled else { outcome = .checkMac; return }
        guard buffer.draft == expectedDraft else { outcome = .checkMac; return }
        // 检查桌面可能异步等待,有效期必须在等待完成后重新读取。
        let (result, attempt) = buffer.beginSend(to: snapshot.target, now: clock())
        guard let attempt else { outcome = Self.map(result); return }
        // 一旦进入适配器,异常或取消均不能证明没有发送;默认锁定重试。
        let delivery: CodexDraftBuffer.Delivery
        do {
            delivery = try await adapter.send(attempt, using: snapshot)
        } catch {
            delivery = .unknown
        }
        _ = buffer.finish(attempt.id, delivery: delivery)
        switch delivery {
        case .confirmed: outcome = .accepted
        case .notSent: outcome = .checkMac
        case .unknown: outcome = .uncertain
        }
    }

    /// 通知续聊允许已有草稿。这里只确认前台的可输入目标，不改变编辑器内容。
    func currentFollowupTarget() async -> CodexDraftTarget? {
        guard let current = try? await adapter.inspectTarget(), current.isFrontmost, current.isUnlocked,
              !current.hasPendingApproval else { return nil }
        return current.target
    }

    func discard() {
        outcome = Self.map(buffer.discard())
    }

    /// 用户开始一段新的硬件录音时，空编辑器代表新的草稿边界。
    /// 只清理内存里的旧发送状态，不修改桌面、不重发旧文字；旧文字仍在时继续保留重试锁。
    func prepareNewDictation() async {
        guard !sendInFlight, !stopInFlight, buffer.attempt == nil, buffer.draft != nil else { return }
        let expectedDraft = buffer.draft
        guard let current = try? await adapter.inspectTarget(), current.isFrontmost, current.isUnlocked,
              current.inputIsEmpty, !current.hasPendingApproval,
              !sendInFlight, !stopInFlight, buffer.attempt == nil, buffer.draft == expectedDraft else { return }
        _ = buffer.discard()
        outcome = .ready
        Log.codex.info("new dictation: empty composer released previous send state")
    }

    /// 对已经显示并绑定的聊天请求中断,与取消草稿和拒绝审批分开。
    func stop(target: CodexDraftTarget) async {
        guard !sendInFlight, !stopInFlight, buffer.attempt == nil else { outcome = .busy; return }
        guard !uncertainStops.contains(target) else { outcome = .uncertain; return }
        stopInFlight = true
        defer { stopInFlight = false }
        let snapshot: CodexTargetSnapshot
        do {
            guard let current = try await adapter.inspectTarget(), current.isFrontmost, current.isUnlocked else {
                outcome = .checkMac
                return
            }
            guard current.target == target else { outcome = .targetChanged; return }
            guard !current.hasPendingApproval else { outcome = .checkMac; return }
            guard current.runState == .running else { outcome = .noTask; return }
            snapshot = current
        } catch {
            outcome = .checkMac
            return
        }
        guard !Task.isCancelled else { outcome = .checkMac; return }
        let delivery: CodexDraftBuffer.Delivery
        do { delivery = try await adapter.stop(using: snapshot) }
        catch { delivery = .unknown }
        switch delivery {
        case .confirmed: outcome = .stopped
        case .notSent: outcome = .checkMac
        case .unknown: uncertainStops.insert(target); outcome = .uncertain
        }
    }

    /// 停止当前前台 Codex 聊天；适用于下键不知道聊天标识、只知道用户正在运行任务的情况。
    func stopCurrent() async {
        guard !sendInFlight, !stopInFlight, buffer.attempt == nil else { outcome = .busy; return }
        stopInFlight = true
        defer { stopInFlight = false }
        let snapshot: CodexTargetSnapshot
        do {
            guard let current = try await adapter.inspectTarget(), current.isFrontmost, current.isUnlocked else {
                outcome = .checkMac
                return
            }
            guard !current.hasPendingApproval else { outcome = .checkMac; return }
            guard current.runState == .running else { outcome = .noTask; return }
            guard !uncertainStops.contains(current.target) else { outcome = .uncertain; return }
            snapshot = current
        } catch {
            outcome = .checkMac
            return
        }
        let delivery: CodexDraftBuffer.Delivery
        do { delivery = try await adapter.stop(using: snapshot) }
        catch { delivery = .unknown }
        switch delivery {
        case .confirmed: outcome = .stopped
        case .notSent: outcome = .checkMac
        case .unknown:
            uncertainStops.insert(snapshot.target)
            outcome = .uncertain
        }
    }

    /// 用户回到 Mac 核实结果后才能解除不确定中断的重试锁。
    func acknowledgeUncertainStop(target: CodexDraftTarget) {
        uncertainStops.remove(target)
        if outcome == .uncertain, uncertainStops.isEmpty, !buffer.requiresReview { outcome = .ready }
    }

    private static func map(_ result: CodexDraftBuffer.Result) -> Outcome {
        switch result {
        case .accepted: .ready
        case .noDraft: .noDraft
        case .expired: .expired
        case .targetChanged: .targetChanged
        case .busy: .busy
        case .uncertain: .uncertain
        case .empty, .staleAttempt: .checkMac
        }
    }

    /// 输入框可能把换行变成段落空格；比较完整内容，避免把另一个草稿误当成待发送文本。
    nonisolated static func inputMatches(_ current: String, _ expected: String) -> Bool {
        normalizedInput(current) == normalizedInput(expected)
    }

    private nonisolated static func normalizedInput(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
