import Foundation

/// 对同一窗口里的可编辑控件排序；分数相同时拒绝猜测，避免把内容写进错误的表单。
nonisolated enum InputCandidateRanking {
    struct Candidate {
        let role: String
        let label: String
        let isWebContent: Bool
        let isBrowser: Bool
        let focused: Bool
    }

    static func score(_ candidate: Candidate) -> Int? {
        let label = candidate.label.lowercased()
        let excluded = ["password", "密码", "address and search", "address bar", "地址栏", "网址栏"]
        if excluded.contains(where: label.contains) { return nil }
        // 浏览器工具栏的地址栏与网页搜索框都是 AXTextField，必须按树的归属区分。
        if candidate.isBrowser && !candidate.isWebContent { return nil }
        if candidate.focused { return 1_000 }
        let comment = ["发表评论", "发评论", "写评论", "评论一下", "说点", "发一条", "留言", "弹幕", "comment"]
        let message = ["发送消息", "输入消息", "发消息", "message", "chat"]
        let reply = ["回复", "reply"]
        let search = ["搜索", "查找", "search", "find"]
        if comment.contains(where: label.contains) { return 320 }
        if message.contains(where: label.contains) { return 300 }
        if reply.contains(where: label.contains) { return 260 }
        if label.contains("评论") { return 280 }
        if candidate.role == "AXTextArea" { return 200 }
        if search.contains(where: label.contains) || candidate.role == "AXSearchField" { return 120 }
        return 100
    }

    static func isSubmitLabel(_ label: String) -> Bool {
        ["发送", "发送消息", "发送评论", "发布", "发布评论", "发表评论", "回复", "发送弹幕",
         "send", "send message", "send comment", "post", "post comment", "submit", "reply"].contains(label)
    }

    static func bestIndex(_ candidates: [Candidate]) -> Int? {
        let ranked = candidates.enumerated().compactMap { index, item in score(item).map { (index, $0) } }
        guard let best = ranked.map(\.1).max() else { return nil }
        let winners = ranked.filter { $0.1 == best }
        return winners.count == 1 ? winners[0].0 : nil
    }
}
