import AppKit
import SwiftUI

/// 入口。菜单栏应用,没有主窗口;所有模块由 AppState 创建。
@main
struct InputBetterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 不使用 SwiftUI 的设置窗口,设置窗口由 WindowManager 管理。
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state
        state.launch()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { state?.handle(url: $0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state?.windows.showSettings()
        return false
    }
}
