import Foundation

/// 编程 Agent(Claude Code 等)的状态通知。
/// Agent 通过 hook 执行 `open -g "inputbetter://agent?event=done&source=Claude%20Code"`,
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
    }

    /// 最近一条未处理的通知(胶囊据此显示提醒)。
    private(set) var current: Notice?
    /// 通知到达时的回调(DeviceBridge 用它转发到设备)。
    @ObservationIgnored var onNotice: ((Notice) -> Void)?
    @ObservationIgnored private var expireTask: Task<Void, Never>?

    /// 处理 `inputbetter://agent?...`;不是 agent URL 时返回 false。
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "inputbetter", url.host == "agent",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let event = Event(rawValue: items.first { $0.name == "event" }?.value ?? "") ?? .done
        let source = items.first { $0.name == "source" }?.value ?? "Agent"
        post(event, source: source)
        return true
    }

    func post(_ event: Event, source: String) {
        let notice = Notice(event: event, source: source, date: Date())
        current = event == .clear ? nil : notice
        onNotice?(notice)
        Log.app.info("agent notice: \(event.rawValue, privacy: .public) from \(source)")
        expireTask?.cancel()
        if event == .done {
            expireTask = Task {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled, current == notice { current = nil }
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
    }
}
