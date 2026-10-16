import AppKit
import ApplicationServices

/// Mac 上已打开、可以切换过去的应用(Passport「切换应用」列表用)。
nonisolated struct SwitchableApp: Equatable, Sendable {
    let pid: pid_t
    let name: String
}

/// 列出已打开的应用并把选中的应用窗口前置、聚焦。
/// 调用链:DeviceBridge.openSwitcher → AppSwitcher.list;DeviceBridge(OK)→ AppSwitcher.activate。
@MainActor
enum AppSwitcher {
    /// 普通应用,按窗口从前到后的顺序排列(最近用过的在前),没有屏幕窗口的排在后面。
    static func list() -> [SwitchableApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
        // CGWindowList 返回的顺序就是前后层级;只看第 0 层的普通窗口,不需要屏幕录制权限(只读 owner PID)。
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [pid_t: Int] = [:]
        for (index, window) in windows.enumerated() where (window[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, order[pid] == nil { order[pid] = index }
        }
        return apps
            .sorted { a, b in
                let oa = order[a.processIdentifier] ?? Int.max, ob = order[b.processIdentifier] ?? Int.max
                if oa != ob { return oa < ob }
                return (a.localizedName ?? "") < (b.localizedName ?? "")
            }
            .map { SwitchableApp(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "App") }
    }

    /// 前置并聚焦,行为与 ⌘Tab / 点 Dock 图标一致:
    /// 1. 应用被隐藏(⌘H)时先取消隐藏;
    /// 2. 通过辅助功能 API 设为最前(后台应用直接调用 activate 可能被系统的"协作激活"拒绝);
    /// 3. 有可见窗口时抬起主窗口;只有最小化窗口时恢复最近的一个;
    /// 4. 完全没有窗口时发送"重新打开"事件,让应用自己新建窗口(和点 Dock 图标相同)。
    static func activate(_ app: SwitchableApp) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        if running.isHidden { running.unhide() }

        let element = AXUIElementCreateApplication(app.pid)
        let frontmost = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        if !frontmost { running.activate(options: [.activateAllWindows]) }

        let windows = axWindows(of: element)
        if let visible = windows.first(where: { !isMinimized($0) }) {
            AXUIElementPerformAction(visible, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(visible, kAXMainAttribute as CFString, kCFBooleanTrue)
        } else if let minimized = windows.first {
            AXUIElementSetAttributeValue(minimized, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(minimized, kAXRaiseAction as CFString)
        } else if let url = running.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    private static func axWindows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}
