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
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        // AX 可能返回成功但只改变逻辑前台，不把窗口从遮挡层抬到最前；始终再调用应用激活，
        // 让自绘窗口和普通应用的 z-order 都按 Dock/⌘Tab 的行为更新。
        _ = running.activate(options: [.activateAllWindows])

        let windows = axWindows(of: element)
        let focused = AgentAX.element(AgentAX.value(element, kAXFocusedWindowAttribute))
        let visible = focused.flatMap { isMinimized($0) ? nil : $0 }
            ?? windows.first(where: { !isMinimized($0) })
        if let visible {
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

    /// 恢复已有输入焦点，或在当前窗口里选择唯一可信的评论、消息或搜索控件。
    /// 浏览器只搜索网页内容，不选择地址栏；候选分数相同时不猜测。
    static func focusTextInput(in running: NSRunningApplication) -> Bool {
        focusedTextInput(in: running) != nil
    }

    static func focusedTextInput(in running: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        guard let window = AgentAX.element(AgentAX.value(app, kAXFocusedWindowAttribute))
                ?? AgentAX.element(AgentAX.value(app, kAXMainWindowAttribute)) else { return nil }
        let focused = AgentAX.element(AgentAX.value(app, kAXFocusedUIElementAttribute))
        let browserIDs = ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser"]
        // 系统注册的 HTTPS 处理程序也视为浏览器，覆盖新安装的 Chromium 变体。
        let handlers = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        let browser = browserIDs.contains { running.bundleIdentifier?.hasPrefix($0) == true }
            || handlers.contains { $0.standardizedFileURL == running.bundleURL?.standardizedFileURL }
        let windowRect = rect(window)
        var stack: [(AXUIElement, Bool, Int)] = [(window, false, 0)]
        var seen = Set<AXUIElement>()
        var nodes: [AXUIElement] = []
        var candidates: [InputCandidateRanking.Candidate] = []
        while let (node, inWeb, depth) = stack.popLast(), seen.count < 12_000 {
            guard seen.insert(node).inserted else { continue }
            let role = AgentAX.string(node, kAXRoleAttribute)
            let web = inWeb || role == "AXWebArea"
            if ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"].contains(role),
               AgentAX.bool(node, kAXEnabledAttribute) != false,
               AgentAX.bool(node, kAXHiddenAttribute) != true,
               AgentAX.bool(node, "AXEditable") != false,
               !AgentAX.string(node, kAXSubroleAttribute).localizedCaseInsensitiveContains("secure"),
               isVisible(node, in: windowRect) {
                var focusSettable = DarwinBoolean(false)
                var valueSettable = DarwinBoolean(false)
                var selectedSettable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(node, kAXFocusedAttribute as CFString, &focusSettable)
                AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &valueSettable)
                AXUIElementIsAttributeSettable(node, kAXSelectedTextAttribute as CFString, &selectedSettable)
                let isFocused = focused.map { CFEqual($0, node) } ?? false
                if isFocused || (focusSettable.boolValue && (valueSettable.boolValue || selectedSettable.boolValue || web)) {
                    let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXIdentifierAttribute, kAXSubroleAttribute]
                        .map { AgentAX.string(node, $0) }.joined(separator: " ")
                    nodes.append(node)
                    candidates.append(.init(role: role, label: label, isWebContent: web, isBrowser: browser, focused: isFocused))
                }
            }
            if depth < 45 {
                for child in AgentAX.children(node).reversed() { stack.append((child, web, depth + 1)) }
            }
        }
        guard let index = InputCandidateRanking.bestIndex(candidates) else { return nil }
        let chosen = nodes[index]
        if candidates[index].focused { return chosen }
        guard AXUIElementSetAttributeValue(chosen, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
              let actual = AgentAX.element(AgentAX.value(app, kAXFocusedUIElementAttribute)), CFEqual(actual, chosen) else { return nil }
        return chosen
    }

    private static func rect(_ node: AXUIElement) -> CGRect? {
        guard let position = AgentAX.value(node, kAXPositionAttribute),
              let size = AgentAX.value(node, kAXSizeAttribute),
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func isVisible(_ node: AXUIElement, in window: CGRect?) -> Bool {
        guard let bounds = rect(node), bounds.width > 2, bounds.height > 2 else { return false }
        return window.map { $0.intersects(bounds) } ?? true
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}
