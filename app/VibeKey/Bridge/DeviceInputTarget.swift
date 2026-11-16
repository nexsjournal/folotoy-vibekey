import AppKit
import ApplicationServices

/// 设备独立于当前桌面焦点工作：先恢复用户选定的应用和输入框，再允许听写结果写入。
@MainActor
final class DeviceInputTarget {
    struct Binding {
        let pid: pid_t
        /// 微信、飞书等自绘应用不一定暴露可比较的 AXWindow;视觉绑定时允许为空。
        let window: AXUIElement?
        enum Input {
            case accessibility(AXUIElement)
            case visual(VisualInputRecipe)
        }
        let input: Input
    }

    private(set) var binding: Binding?
    private var preferredPID: pid_t?
    private let settings: AppSettings
    private var accessibilityPrepared: Set<pid_t> = []
    private let codexAdapter = AccessibilityCodexDesktopAdapter()
    init(settings: AppSettings) { self.settings = settings }

    /// 同一 Bundle ID 可能运行多个浏览器实例；优先恢复设备上明确选中的进程。
    func remember(processID: pid_t) { preferredPID = processID }

    func prepare() async throws -> NSRunningApplication {
        try Task.checkCancellation()
        binding = nil
        let identifier = settings.deviceTargetBundleID
        let workspace = NSWorkspace.shared
        let running: NSRunningApplication
        let matches = workspace.runningApplications.filter { $0.bundleIdentifier == identifier && !$0.isTerminated }
        if let app = matches.first(where: { $0.processIdentifier == preferredPID }) ?? matches.first {
            running = app
        } else if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            running = try await workspace.openApplication(at: url, configuration: configuration)
        } else {
            throw Failure.unavailable
        }
        try Task.checkCancellation()
        if !accessibilityPrepared.contains(running.processIdentifier),
           ElectronAccessibility.enable(processID: running.processIdentifier) {
            accessibilityPrepared.insert(running.processIdentifier)
        }
        AppSwitcher.activate(.init(pid: running.processIdentifier, name: running.localizedName ?? identifier))
        // Chromium 默认延迟暴露网页 AX 树；在窗口上请求增强辅助功能，随后由下方重试等待建树。
        // 某些版本返回 cannotComplete，但仍会异步启用，因此不能以返回码判断是否成功。
        if let window = AgentAX.element(AgentAX.value(AXUIElementCreateApplication(running.processIdentifier), kAXFocusedWindowAttribute)) {
            AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        // 以设置里已选中的标识判断专项兜底；运行中进程的 Bundle ID 偶尔可能由启动器或
        // 包内组件返回空值，不能让这种情况把微信误判成未知应用。
        let visualRecipe = VisualInputFallback.recipe(for: identifier)
        // 从别的全屏 Space（例如 Magpie）切到 Codex 时，系统切换动画加 Chromium 首次建 AX 树
        // 可能超过 2 秒；预检多等一会儿，避免把"还没建好"误报成"没有输入框"。
        let startedAt = Date()
        let deadline = ContinuousClock.now + .seconds(visualRecipe == nil ? 5 : 3)
        var nextActivation = Date()
        var openedForActivation = false
        var probedCodex = false
        repeat {
            try Task.checkCancellation()
            // 某些自绘应用首次启动或跨 Space 激活较慢；必要时重试前置，避免一次失败后空等。
            if workspace.frontmostApplication?.processIdentifier != running.processIdentifier,
               Date() >= nextActivation {
                AppSwitcher.activate(.init(pid: running.processIdentifier, name: running.localizedName ?? identifier))
                // AX 的“设为最前”可能只改逻辑焦点，不调整实际窗口层级；再让 LaunchServices
                // 按打开已有应用的方式补一次激活，避免视觉坐标点到覆盖在目标窗口上方的其他应用。
                if !openedForActivation, Date().timeIntervalSince(startedAt) >= 0.5,
                   let url = running.bundleURL ?? workspace.urlForApplication(withBundleIdentifier: identifier) {
                    openedForActivation = true
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    _ = try? await workspace.openApplication(at: url, configuration: configuration)
                }
                nextActivation = Date().addingTimeInterval(0.5)
            }
            if workspace.frontmostApplication?.processIdentifier == running.processIdentifier {
                if let input = AppSwitcher.focusedTextInput(in: running),
                   let window = AgentAX.element(AgentAX.value(AXUIElementCreateApplication(running.processIdentifier), kAXFocusedWindowAttribute)) {
                    binding = Binding(pid: running.processIdentifier, window: window, input: .accessibility(input))
                    Log.codex.info("device input target ready in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                    return running
                }
                // 微信 4.x 的正文树为空；窗口稳定后按已验证的固定布局点击输入区。
                if let visualRecipe, Date().timeIntervalSince(startedAt) >= 0.25,
                   let focused = VisualInputFallback.focus(running, recipe: visualRecipe) {
                    // Codex 首次点击编辑器后会立即建立完整 Chromium AX 树。优先在点击后重新绑定
                    // 真实输入控件，让后续发送仍能核对同一会话与完整草稿；树仍未就绪时才保留视觉绑定。
                    if running.bundleIdentifier == AccessibilityCodexDesktopAdapter.bundleIdentifier {
                        try? await Task.sleep(for: .milliseconds(120))
                        if let input = AppSwitcher.focusedTextInput(in: running),
                           let window = AgentAX.element(AgentAX.value(
                            AXUIElementCreateApplication(running.processIdentifier),
                            kAXFocusedWindowAttribute
                           )) {
                            binding = Binding(pid: running.processIdentifier, window: window,
                                              input: .accessibility(input))
                            Log.codex.info("Codex composer AX tree ready after visual focus")
                            return running
                        }
                    }
                    let window = AgentAX.element(AgentAX.value(AXUIElementCreateApplication(running.processIdentifier), kAXFocusedWindowAttribute))
                    binding = Binding(pid: running.processIdentifier, window: window, input: .visual(focused))
                    Log.codex.info("visual input target ready in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                    return running
                }
                // Codex 的网页编辑器可能不在窗口子树中，或 Chromium 首次延迟建树。
                // 通用遍历连续失败后，用 Codex 自己的 AX 适配器再确认一次。
                if !probedCodex,
                   running.bundleIdentifier == AccessibilityCodexDesktopAdapter.bundleIdentifier,
                   Date().timeIntervalSince(startedAt) >= 0.6 {
                    probedCodex = true
                    if (try? await codexAdapter.inspectTarget()) != nil {
                        Log.codex.info("device input target ready via Codex adapter in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
                        return running
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(60))
        } while ContinuousClock.now < deadline
        Log.codex.notice("device input target unavailable before deadline")
        throw Failure.noInput
    }

    /// 录音开始时绑定控件；粘贴前核对前台应用、窗口和输入焦点，避免切换标签后写错位置。
    func validate(_ target: Binding) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { throw Failure.noInput }
        let app = AXUIElementCreateApplication(target.pid)
        switch target.input {
        case .accessibility(let input):
            guard let expectedWindow = target.window,
                  let window = AgentAX.element(AgentAX.value(app, kAXFocusedWindowAttribute)),
                  CFEqual(window, expectedWindow),
                  let focus = AgentAX.element(AgentAX.value(app, kAXFocusedUIElementAttribute)),
                  CFEqual(focus, input) else {
                throw Failure.noInput
            }
        case .visual(let recipe):
            guard let running = NSRunningApplication(processIdentifier: target.pid),
                  let frame = VisualInputFallback.windowFrame(for: target.pid),
                  recipe.matches(frame),
                  VisualInputFallback.focus(running, recipe: recipe) != nil else {
                throw Failure.noInput
            }
        }
    }

    /// 提交时恢复目标应用，但不重新挑选输入框；失焦或切换网页时拒绝发送。
    func prepareForSend(_ target: Binding) async throws -> NSRunningApplication {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.bundleIdentifier == settings.deviceTargetBundleID else { throw Failure.unavailable }
        AppSwitcher.activate(.init(pid: target.pid, name: app.localizedName ?? "App"))
        for _ in 0..<30 {
            try Task.checkCancellation()
            if (try? validate(target)) != nil { return app }
            try await Task.sleep(for: .milliseconds(60))
        }
        throw Failure.noInput
    }

    /// 优先按输入框邻近的唯一发送按钮；搜索框和没有可识别按钮的控件使用回车。
    func submit(_ target: Binding) throws {
        try validate(target)
        if case .visual(let recipe) = target.input {
            guard let app = NSRunningApplication(processIdentifier: target.pid),
                  VisualInputFallback.submit(app, recipe: recipe) else { throw Failure.noInput }
            return
        }
        guard case .accessibility(let input) = target.input else { throw Failure.noInput }
        guard let expectedWindow = target.window else { throw Failure.noInput }
        let label = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
            .map { AgentAX.string(input, $0).lowercased() }.joined(separator: " ")
        if ["search", "搜索", "查找"].contains(where: label.contains) {
            guard KeySender.perform(.enter) else { throw Failure.noInput }
            return
        }
        var parent = AgentAX.element(AgentAX.value(input, kAXParentAttribute))
        for _ in 0..<5 {
            guard let scope = parent, !CFEqual(scope, expectedWindow) else { break }
            let buttons = AgentAX.all(in: scope, maxDepth: 5, maxNodes: 250) { node in
                guard AgentAX.string(node, kAXRoleAttribute) == "AXButton",
                      AgentAX.bool(node, kAXEnabledAttribute) != false,
                      AgentAX.bool(node, kAXHiddenAttribute) != true,
                      AgentAX.hasAction(node, kAXPressAction as String) else { return false }
                let title = [kAXTitleAttribute, kAXDescriptionAttribute, "AXHelp"]
                    .map { AgentAX.string(node, $0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                return title.contains(where: InputCandidateRanking.isSubmitLabel)
            }
            if buttons.count == 1 {
                // 可能已由应用异步处理；失败时不补发回车，避免重复提交。
                guard AgentAX.press(buttons[0]) else { throw Failure.noInput }
                return
            }
            if buttons.count > 1 { throw Failure.noInput }
            parent = AgentAX.element(AgentAX.value(scope, kAXParentAttribute))
        }
        guard KeySender.perform(.enter) else { throw Failure.noInput }
    }

    enum Failure: LocalizedError {
        case unavailable, noInput
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "找不到选定的目标应用，请在设备上重新选择应用", bundle: .l10n)
            case .noInput: String(localized: "目标应用没有可用的输入框，请先在该应用选择输入位置", bundle: .l10n)
            }
        }
    }
}
