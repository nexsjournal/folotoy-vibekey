import AppKit

/// 字幕记录窗口的"固定在右侧":
/// - 固定:贴屏幕右边、占满可用高度(避开菜单栏和程序坞),窗口层级升到 floating,始终在其他窗口前面;
///   在所有桌面空间和全屏应用旁都显示;不能拖动(宽度仍可调整);
///   外观改成和字幕条一样的深色半透明玻璃(窗口透明 + 深色外观,背景由 TranscriptView 画玻璃)。
/// - 取消固定:恢复普通层级、不透明窗口和原来的位置尺寸(固定期间暂停自动保存窗口位置,取消时从保存的位置恢复)。
/// 固定状态记在 UserDefaults,下次打开窗口沿用。屏幕变化(接显示器、改分辨率)时重新贴边。
@MainActor @Observable
final class TranscriptPinController {
    private(set) var isPinned: Bool
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private let autosaveName: String
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults

    private static let pinnedKey = "transcriptPinned"
    /// 固定时的宽度范围。
    private static let pinnedWidth: ClosedRange<CGFloat> = 360...560

    init(autosaveName: String, defaults: UserDefaults = .standard) {
        self.autosaveName = autosaveName
        self.defaults = defaults
        isPinned = defaults.bool(forKey: Self.pinnedKey)
    }

    /// 绑定窗口并按保存的状态应用。
    func attach(_ window: NSWindow) {
        self.window = window
        if isPinned { pin() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPinned else { return }
                self.pin()
            }
        }
    }

    func toggle() {
        isPinned.toggle()
        defaults.set(isPinned, forKey: Self.pinnedKey)
        isPinned ? pin() : unpin()
    }

    private func pin() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        // 先停止自动保存,避免把贴边的位置当成用户的窗口位置记下来。
        window.setFrameAutosaveName("")
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovable = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        let visible = screen.visibleFrame
        let width = min(max(window.frame.width, Self.pinnedWidth.lowerBound), Self.pinnedWidth.upperBound)
        window.setFrame(NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height), display: true, animate: true)
    }

    private func unpin() {
        guard let window else { return }
        window.level = .normal
        window.collectionBehavior = []
        window.isMovable = true
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.appearance = nil
        // 重新设置自动保存名会把窗口恢复到之前保存的位置和尺寸。
        if !window.setFrameUsingName(autosaveName) {
            window.setContentSize(NSSize(width: 560, height: 620))
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)
    }
}
