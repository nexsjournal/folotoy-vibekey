import AppKit
import SwiftUI

/// 入口。菜单栏应用,没有主窗口;所有模块由 AppState 创建。
@main
struct VibeKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 不使用 SwiftUI 的设置窗口,设置窗口由 WindowManager 管理。
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(String(localized: "设置…", bundle: .l10n)) {
                        delegate.state?.windows.showSettings()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var state: AppState?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CodexAccessDiagnostics.runIfRequested() { return }
        if VoicePipelineDiagnostics.runIfRequested() { return }
        // XCTest 使用 app 作为宿主;测试时不能启动串口、蓝牙或后台服务。
        guard ProcessInfo.processInfo.environment["IB_TEST_MODE"] != "1" else { return }
        let state = AppState()
        self.state = state
        state.launch()
        pendingURLs.forEach { state.handle(url: $0) }
        pendingURLs.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let state { urls.forEach { state.handle(url: $0) } }
        else { pendingURLs = Array((pendingURLs + urls).suffix(16)) }
    }

    /// 字幕还在进行时退出要确认一次(app 不保存历史,退出后记录就没了);用户取消则不退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.prepareToQuit() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state?.windows.showSettings()
        return false
    }
}
