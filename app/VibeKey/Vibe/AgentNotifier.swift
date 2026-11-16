import Foundation

/// 编程 Agent(Claude Code 等)的状态通知。
/// Agent 通过 hook 执行 `open -g "folobutton-dev://agent?event=done&source=Claude%20Code"`,
/// app 收到 URL 后在 Passport 屏幕和胶囊上提醒你:任务完成了,或者在等你确认。
@MainActor @Observable
final class AgentNotifier {
    enum Event: String {
        case done, input, clear
    }

    struct Notice: Equatable {
        let id: UUID = UUID()
        let event: Event
        let source: String
        let date: Date
        var threadID: UUID? = nil
        var project: String? = nil
        var summary: String? = nil
    }

    /// 最近一条未处理的通知(胶囊据此显示提醒)。
    private(set) var current: Notice?
    /// 通知到达时的回调(DeviceBridge 用它转发到设备)。
    @ObservationIgnored var onSummaryUpdate: ((Notice) -> Void)?
    @ObservationIgnored private let processor: TextProcessor?
    @ObservationIgnored var onNotice: ((Notice) -> Void)?
    /// 当前摘要尚未处理时，后续完成仍要各发一次完成提醒；摘要继续按顺序排队。
    @ObservationIgnored var onQueuedCompletion: ((Notice) -> Void)?
    @ObservationIgnored private var expireTask: Task<Void, Never>?
    @ObservationIgnored private var waiting: [Notice] = []
    @ObservationIgnored private var recentTurns: [String] = []
    /// Hook 与本地日志可能同时看到同一轮完成；同一来源、同一摘要在短窗口内只提醒一次。
    @ObservationIgnored private var recentCompletionFingerprints: [(key: String, date: Date)] = []
    @ObservationIgnored private var completionPause: Task<Void, Never>?

    init(processor: TextProcessor? = nil) { self.processor = processor }

    /// 处理 `folobutton-dev://agent?...`;不是 agent URL 时返回 false。
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "folobutton-dev", url.host == "agent",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let event = Event(rawValue: item("event") ?? "") else { return false }
        let source = item("source") ?? "Agent"
        // 即使轮次重复，也消费临时文件，避免敏感正文遗留在磁盘。
        let reply = item("payload").flatMap { AgentCompletionInbox.consume($0) }
        let summary = reply.map(AgentCompletionSummary.fallback).flatMap { $0.isEmpty ? nil : $0 }
        var threadID: UUID?
        if event == .done, source == "Codex", let rawID = item("thread"), !rawID.isEmpty {
            guard let parsed = UUID(uuidString: rawID) else { return false }
            threadID = parsed
            if let turn = item("turn"), !turn.isEmpty {
                let key = parsed.uuidString + ":" + String(turn.prefix(100))
                if recentTurns.contains(key) { return true }
                recentTurns.append(key)
                if recentTurns.count > 64 { recentTurns.removeFirst() }
            }
        }
        if event == .done, let reply, let summary {
            guard acceptCompletionFingerprint(source: source, summary: summary) else { return true }
            let notice = Notice(event: event, source: source, date: Date(), threadID: threadID,
                                project: item("project").flatMap { $0.isEmpty ? nil : String($0.prefix(30)) }, summary: summary)
            enqueue(notice)
            summarize(reply, noticeID: notice.id)
        } else if let threadID {
            enqueue(Notice(event: event, source: source, date: Date(), threadID: threadID,
                           project: item("project").flatMap { $0.isEmpty ? nil : String($0.prefix(30)) }))
        } else {
            post(event, source: source)
        }
        return true
    }

    /// 本地终态监听器与 Hook 共用入口；正文只留在内存，设备只收到摘要。
    func postCompletion(_ event: AgentCompletionEvent) {
        let reply = event.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = AgentCompletionSummary.fallback(reply)
        guard !summary.isEmpty,
              acceptCompletionFingerprint(source: event.source, summary: summary) else { return }
        let notice = Notice(
            event: .done, source: event.source, date: Date(),
            threadID: event.threadID, project: event.project, summary: summary
        )
        enqueue(notice)
        summarize(reply, noticeID: notice.id)
    }

    func post(_ event: Event, source: String) {
        if event == .clear {
            waiting.removeAll { $0.source == source && $0.event == .input }
            // 旧清除事件没有会话 ID，不能清掉另一个对话的完成卡。
            if current?.threadID == nil && current?.summary == nil { dismiss() }
            return
        }
        enqueue(Notice(event: event, source: source, date: Date()))
    }

    /// 后台压缩，结果只更新仍在队列中的对应通知，不打断已经阅读或关闭的另一条。
    private func summarize(_ text: String, noticeID: UUID) {
        guard let processor, processor.isAvailable, text.count > 180 else { return }
        Task { [weak self] in
            guard let reply = try? await processor.summarizeAgentReply(text) else { return }
            let summary = AgentCompletionSummary.fallback(reply)
            guard !summary.isEmpty, let self else { return }
            if var current = self.current, current.id == noticeID {
                current.summary = summary
                self.current = current
                self.onSummaryUpdate?(current)
            } else if let index = self.waiting.firstIndex(where: { $0.id == noticeID }) {
                self.waiting[index].summary = summary
            }
        }
    }

    private func enqueue(_ notice: Notice) {
        if current?.threadID != nil || current?.summary != nil || ((notice.threadID != nil || notice.summary != nil) && (current != nil || completionPause != nil)) {
            if waiting.count == 8 { waiting.removeFirst() }
            waiting.append(notice)
            if notice.event == .done, completionPause == nil {
                onQueuedCompletion?(notice)
            }
            Log.app.info("agent notice queued: \(notice.event.rawValue, privacy: .public), thread-bound=\(notice.threadID != nil)")
        } else { show(notice) }
    }

    private func acceptCompletionFingerprint(source: String, summary: String) -> Bool {
        let now = Date()
        recentCompletionFingerprints.removeAll { now.timeIntervalSince($0.date) > 12 }
        let key = source + "\u{0}" + summary
        guard !recentCompletionFingerprints.contains(where: { $0.key == key }) else { return false }
        recentCompletionFingerprints.append((key, now))
        if recentCompletionFingerprints.count > 64 {
            recentCompletionFingerprints.removeFirst(recentCompletionFingerprints.count - 64)
        }
        return true
    }

    private func show(_ notice: Notice) {
        let event = notice.event
        current = event == .clear ? nil : notice
        onNotice?(notice)
        Log.app.info("agent notice: \(event.rawValue, privacy: .public) from \(notice.source), thread-bound=\(notice.threadID != nil)")
        expireTask?.cancel()
        if event == .done, notice.summary == nil {
            expireTask = Task {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled, current == notice { dismiss() }
            }
        }
    }

    /// 用户已看到。在 Mac 上关掉(点了胶囊等)时同时清除设备上的提醒;
    /// 设备上按键确认的(`fromDevice`)设备已经自己清掉了,不用再发。
    func dismiss(fromDevice: Bool = false) {
        guard let notice = current else { return }
        current = nil
        expireTask?.cancel()
        if !fromDevice { onNotice?(Notice(event: .clear, source: notice.source, date: Date())) }
        showNext()
    }

    /// 打开原对话后给下一次 OK 留出时间。用户可以停在草稿，因此必须自动恢复通知。
    func pauseCompletedNotices(for duration: Duration = .seconds(20)) {
        completionPause?.cancel()
        completionPause = Task { [weak self] in
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { self?.resumeCompletedNotices() }
        }
    }

    func resumeCompletedNotices() {
        completionPause?.cancel()
        completionPause = nil
        showNext()
    }

    private func showNext() {
        guard current == nil, let index = waiting.firstIndex(where: { completionPause == nil || $0.event != .done }) else { return }
        show(waiting.remove(at: index))
    }
}
