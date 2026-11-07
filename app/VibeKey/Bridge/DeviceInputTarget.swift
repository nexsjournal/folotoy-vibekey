import AppKit
import ApplicationServices

/// 设备独立于当前桌面焦点工作：先恢复用户选定的应用和输入框，再允许听写结果写入。
@MainActor
final class DeviceInputTarget {
    private let settings: AppSettings
    private var accessibilityPrepared: Set<pid_t> = []
    private let codexAdapter = AccessibilityCodexDesktopAdapter()
    init(settings: AppSettings) { self.settings = settings }

    func prepare() async throws -> NSRunningApplication {
        try Task.checkCancellation()
        let identifier = settings.deviceTargetBundleID
        let workspace = NSWorkspace.shared
        let running: NSRunningApplication
        if let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == identifier && !$0.isTerminated }) {
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
        // 从别的全屏 Space（例如 Magpie）切到 Codex 时，系统切换动画加 Chromium 首次建 AX 树
        // 可能超过 2 秒；预检多等一会儿，避免把"还没建好"误报成"没有输入框"。
        let startedAt = Date()
        let deadline = ContinuousClock.now + .seconds(5)
        var probedCodex = false
        repeat {
            try Task.checkCancellation()
            if workspace.frontmostApplication?.processIdentifier == running.processIdentifier {
                if AppSwitcher.focusTextInput(in: running) {
                    Log.codex.info("device input target ready in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s")
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
        Log.codex.notice("device input target unavailable after 5s")
        throw Failure.noInput
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
