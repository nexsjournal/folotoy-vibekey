import AppKit
import SwiftUI

/// 屏幕底部的胶囊状态条窗口。胶囊和字幕条是同一个表面:字幕开启时胶囊变形成字幕条。
/// - 窗口固定较大且透明,形状变化全部在 SwiftUI 里用动画完成,避免频繁改窗口尺寸造成闪烁;
/// - 只有鼠标位于胶囊 / 字幕条区域时才接收鼠标事件,其余透明区域点击穿透到下面的应用;
/// - 悬停检测用全局鼠标移动监听(窗口穿透时 NSTrackingArea 收不到事件);
/// - 可以拖动,位置以"相对屏幕底部中央的偏移"保存,换屏幕、改分辨率后仍然合理。
@MainActor
final class PillPanelController {
    /// 界面状态(悬停、字幕条是否收起),PillView 读取。
    let ui = PillUIState()

    private let panel: PillPanel
    private let settings: AppSettings
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// 可交互区域(窗口坐标,原点左上),由 SwiftUI 回传;为空表示整块穿透(字幕条锁定时)。
    private var hotRect: CGRect = .zero
    /// 拖动起点:鼠标位置与窗口原点。
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// 透明窗口的大小(只有字幕条 / 胶囊所在的区域接收鼠标):高度要放得下最大字号下 3 行原文 + 5 行译文。
    static let size = NSSize(width: 980, height: 480)
    private static let offsetKey = "pillOffset"

    init(content: (PillUIState, PillWindowActions) -> AnyView, settings: AppSettings) {
        self.settings = settings
        panel = PillPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let windowActions = PillWindowActions(
            reportHotRect: { [weak self] rect in self?.hotRect = rect },
            dragChanged: { [weak self] in self?.dragChanged() },
            dragEnded: { [weak self] in self?.dragEnded() })
        let host = NSHostingView(rootView: content(ui, windowActions))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
    }

    /// 显示状态条。用户在设置里隐藏了状态条时只有 `force`(字幕运行 / 选择字幕应用)才显示,
    /// 因为字幕条就是状态条,不显示就看不到字幕。
    func show(force: Bool = false) {
        guard settings.showPill || force else { return }
        reposition()
        panel.orderFrontRegardless()
        startMouseTracking()
    }

    func hide() {
        panel.orderOut(nil)
        stopMouseTracking()
    }

    /// 放到鼠标所在屏幕的底部中央,再加上用户拖动过的偏移。
    func reposition() {
        guard dragStart == nil, let frame = currentScreen()?.visibleFrame else { return }
        let offset = savedOffset
        var origin = NSPoint(x: frame.midX - Self.size.width / 2 + offset.x, y: frame.minY + 4 + offset.y)
        // 保证胶囊中心仍在屏幕内。
        origin.x = min(max(origin.x, frame.minX - Self.size.width / 2), frame.maxX - Self.size.width / 2)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - Self.size.height)
        panel.setFrameOrigin(origin)
    }

    /// 回到默认位置(底部中央)。
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.offsetKey)
        reposition()
    }


    /// 在胶囊上方弹出菜单(快捷键触发、没有点击位置时使用)。
    func popUpAtPill(_ menu: NSMenu) {
        let rect = hotRect.isEmpty ? CGRect(x: Self.size.width / 2, y: Self.size.height - 20, width: 0, height: 0) : hotRect
        popUp(menu, at: CGPoint(x: rect.midX, y: rect.minY - 4))
    }

    /// 在按钮正上方弹出菜单:菜单底边贴着按钮顶部(`viewPoint`,窗口坐标、原点左上),水平居中,不遮住胶囊。
    /// `NSMenu.popUp(at:)` 的位置是菜单左上角,坐标系跟随视图:SwiftUI 的托管视图是翻转坐标(y 向下),
    /// 所以左上角 = 按钮顶部再往上一个菜单高度。按非翻转坐标算会差出一整个窗口高度(菜单离胶囊很远,或盖住胶囊)。
    func popUp(_ menu: NSMenu, at viewPoint: CGPoint) {
        guard let view = panel.contentView else { return }
        let size = menu.size
        let top = view.isFlipped ? viewPoint.y - size.height : view.bounds.height - viewPoint.y + size.height
        menu.popUp(positioning: nil, at: NSPoint(x: viewPoint.x - size.width / 2, y: top), in: view)
    }

    // MARK: - 拖动

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func dragEnded() {
        dragStart = nil
        guard let frame = currentScreen()?.visibleFrame else { return }
        let offset = NSPoint(x: panel.frame.minX - (frame.midX - Self.size.width / 2), y: panel.frame.minY - (frame.minY + 4))
        UserDefaults.standard.set(NSStringFromPoint(offset), forKey: Self.offsetKey)
    }

    private var savedOffset: NSPoint {
        UserDefaults.standard.string(forKey: Self.offsetKey).map(NSPointFromString) ?? .zero
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    // MARK: - 鼠标跟踪

    private func startMouseTracking() {
        guard monitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    private func stopMouseTracking() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func updateHover() {
        // 拖动过程中保持可交互。
        if dragStart != nil { return }
        let mouse = NSEvent.mouseLocation
        // 窗口坐标(左上原点)转屏幕坐标(左下原点)。
        let screenRect = CGRect(
            x: panel.frame.minX + hotRect.minX,
            y: panel.frame.maxY - hotRect.maxY,
            width: hotRect.width,
            height: hotRect.height
        ).insetBy(dx: -6, dy: -6)
        let inside = !hotRect.isEmpty && screenRect.contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if ui.isHovering != inside { ui.isHovering = inside }
    }
}

/// 视图回传给窗口控制器的动作。
struct PillWindowActions {
    var reportHotRect: (CGRect) -> Void
    var dragChanged: () -> Void
    var dragEnded: () -> Void
}

/// 不抢焦点的面板:点击按钮时当前应用的输入焦点保持不变。
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 状态条的界面状态。
@MainActor @Observable
final class PillUIState {
    var isHovering = false
    /// 字幕运行时把字幕条收起成小胶囊(Passport 下键 / 字幕条上的收起按钮)。
    var subtitleCollapsed = false
}
