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
        let event: Event
        let source: String
        let date: Date
        var threadID: UUID? = nil
        var project: String? = nil
    }

    /// 最近一条未处理的通知(胶囊据此显示提醒)。
    private(set) var current: Notice?
    /// 通知到达时的回调(DeviceBridge 用它转发到设备)。
    @ObservationIgnored var onNotice: ((Notice) -> Void)?
    @ObservationIgnored private var expireTask: Task<Void, Never>?
    @ObservationIgnored private var waiting: [Notice] = []
    @ObservationIgnored private var recentTurns: [String] = []
    @ObservationIgnored private var completionPause: Task<Void, Never>?

    /// 处理 `folobutton-dev://agent?...`;不是 agent URL 时返回 false。
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "folobutton-dev", url.host == "agent",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let event = Event(rawValue: item("event") ?? "") else { return false }
        let source = item("source") ?? "Agent"
        if event == .done, source == "Codex", let rawID = item("thread") {
            guard let threadID = UUID(uuidString: rawID) else { return false }
            if let turn = item("turn"), !turn.isEmpty {
                let key = threadID.uuidString + ":" + String(turn.prefix(100))
                if recentTurns.contains(key) { return true }
                recentTurns.append(key)
                if recentTurns.count > 64 { recentTurns.removeFirst() }
            }
            enqueue(Notice(event: event, source: source, date: Date(), threadID: threadID,
                           project: item("project").flatMap { $0.isEmpty ? nil : String($0.prefix(30)) }))
        } else {
            post(event, source: source)
        }
        return true
    }

    func post(_ event: Event, source: String) {
        if event == .clear {
            waiting.removeAll { $0.source == source && $0.event == .input }
            // 旧清除事件没有会话 ID，不能清掉另一个对话的完成卡。
            if current?.threadID == nil { dismiss() }
            return
        }
        enqueue(Notice(event: event, source: source, date: Date()))
    }

    private func enqueue(_ notice: Notice) {
        if current?.threadID != nil || (notice.threadID != nil && (current != nil || completionPause != nil)) {
            if waiting.count == 8 { waiting.removeFirst() }
            waiting.append(notice)
            Log.app.info("agent notice queued: \(notice.event.rawValue, privacy: .public), thread-bound=\(notice.threadID != nil)")
        } else { show(notice) }
    }

    private func show(_ notice: Notice) {
        let event = notice.event
        current = event == .clear ? nil : notice
        onNotice?(notice)
        Log.app.info("agent notice: \(event.rawValue, privacy: .public) from \(notice.source), thread-bound=\(notice.threadID != nil)")
        expireTask?.cancel()
        if event == .done {
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
        guard current == nil, let index = waiting.firstIndex(where: { completionPause == nil || $0.threadID == nil }) else { return }
        show(waiting.remove(at: index))
    }
}
