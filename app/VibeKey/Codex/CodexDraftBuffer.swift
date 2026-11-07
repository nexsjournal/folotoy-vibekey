import Foundation

/// 由桌面适配器确认的唯一目标。缺少任一标识时不能创建,避免把未知值当成同一个聊天。
nonisolated struct CodexDraftTarget: Hashable, Sendable {
    let processID: Int32
    let windowID: String
    let conversationID: String
    let inputID: String

    init?(processID: Int32, windowID: String, conversationID: String, inputID: String) {
        guard processID > 0, !windowID.isEmpty, !conversationID.isEmpty, !inputID.isEmpty else { return nil }
        self.processID = processID
        self.windowID = windowID
        self.conversationID = conversationID
        self.inputID = inputID
    }

    /// 提交前仍要求全部标识相同；仅回执读取允许同一聊天重建输入节点。
    func isSameConversation(as other: Self) -> Bool {
        processID == other.processID && windowID == other.windowID && conversationID == other.conversationID
    }
}

/// 单条内存草稿及其发送租约。调用方负责在采音和发送前分别验证目标、权限及桌面状态。
/// 不执行输入或发送;只有明确失败才允许重新尝试,结果不明时保留草稿并锁定重发。
nonisolated struct CodexDraftBuffer {
    enum Result: Equatable {
        case accepted, empty, expired, targetChanged, busy, uncertain, noDraft, staleAttempt
    }

    enum Delivery {
        case confirmed
        /// 确认未发送,可重新核对目标后重试。
        case notSent
        /// 无法确认是否发送,不能自动重试。
        case unknown
    }

    struct Draft: Equatable {
        /// 每次新建或追加都更新,避免异步检查期间草稿被替换后误发。
        var generation: UUID
        let target: CodexDraftTarget
        var text: String
        let expiresAt: Date
    }

    struct Attempt: Equatable {
        let id: UUID
        let draft: Draft
    }

    private(set) var draft: Draft?
    private(set) var attempt: Attempt?
    private(set) var requiresReview = false

    /// 续说只能追加到原目标;新录音不能延长第一段的有效期。
    mutating func append(_ text: String, target: CodexDraftTarget, expiresAt: Date, now: Date) -> Result {
        let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return .empty }
        guard !requiresReview else { return .uncertain }
        guard attempt == nil else { return .busy }
        if var current = draft {
            guard now < current.expiresAt else { return .expired }
            guard current.target == target else { return .targetChanged }
            current.text += "\n" + segment
            current.generation = UUID()
            draft = current
        } else {
            guard now < expiresAt else { return .expired }
            draft = Draft(generation: UUID(), target: target, text: segment, expiresAt: expiresAt)
        }
        return .accepted
    }

    /// 获取一次性发送租约;目标必须是刚刚重新检查过的目标。
    mutating func beginSend(to target: CodexDraftTarget, now: Date) -> (Result, Attempt?) {
        guard !requiresReview else { return (.uncertain, nil) }
        guard attempt == nil else { return (.busy, nil) }
        guard let draft else { return (.noDraft, nil) }
        guard now < draft.expiresAt else { return (.expired, nil) }
        guard draft.target == target else { return (.targetChanged, nil) }
        let lease = Attempt(id: UUID(), draft: draft)
        attempt = lease
        return (.accepted, lease)
    }

    /// 只接受当前租约的回执,迟到或重复回执不能改变新草稿。
    mutating func finish(_ id: UUID, delivery: Delivery) -> Result {
        guard attempt?.id == id else { return .staleAttempt }
        attempt = nil
        switch delivery {
        case .confirmed: draft = nil
        case .notSent: break
        case .unknown: requiresReview = true
        }
        return .accepted
    }

    /// 用户明确丢弃草稿时使用;正在发送时先等待回执或将其标记为 unknown。
    mutating func discard() -> Result {
        guard attempt == nil else { return .busy }
        draft = nil
        requiresReview = false
        return .accepted
    }
}
