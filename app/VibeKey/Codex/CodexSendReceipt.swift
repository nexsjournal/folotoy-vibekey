import Foundation

/// 发送后的只读证据。输入节点可在提交后重建，但不能把切聊天、编辑文字或失去焦点当作发送成功。
nonisolated enum CodexSendReceipt {
    static func confirms(_ after: CodexTargetSnapshot, target: CodexDraftTarget) -> Bool {
        after.target.isSameConversation(as: target) && after.isFrontmost && after.isUnlocked
            && !after.hasPendingApproval && after.inputIsEmpty
    }
}
