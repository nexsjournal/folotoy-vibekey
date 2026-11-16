import AppKit
import CoreGraphics

/// 自绘应用未暴露输入控件时使用的窗口相对坐标。
///
/// 微信 4.x 的聊天正文在独立渲染进程中，主窗口的 AX 树只暴露标题栏按钮；
/// 因此不能依赖 `AXTextArea`。当前配方已在本机微信 4.1 实测输入和发送区域。
nonisolated struct VisualInputRecipe: Equatable {
    let bundleID: String
    let inputX: CGFloat
    let inputY: CGFloat
    let submitX: CGFloat
    let submitY: CGFloat

    func inputPoint(in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + frame.width * inputX, y: frame.minY + frame.height * inputY)
    }

    func submitPoint(in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + frame.width * submitX, y: frame.minY + frame.height * submitY)
    }

    func matches(_ frame: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(frame.minX - expectedFrame.minX) <= tolerance
            && abs(frame.minY - expectedFrame.minY) <= tolerance
            && abs(frame.width - expectedFrame.width) <= tolerance
            && abs(frame.height - expectedFrame.height) <= tolerance
    }

    var expectedFrame: CGRect = .zero
}

/// 只在已知且已验证布局的应用上使用；未知应用不会猜测点击位置。
@MainActor
enum VisualInputFallback {
    static let weChat = VisualInputRecipe(
        bundleID: "com.tencent.xinWeChat",
        inputX: 0.58,
        inputY: 0.89,
        submitX: 0.93,
        submitY: 0.95
    )
    static let feishu = VisualInputRecipe(
        bundleID: "com.electron.lark",
        inputX: 0.58,
        inputY: 0.955,
        submitX: 0.93,
        submitY: 0.955
    )
    /// Codex 的 Chromium 渲染树在输入区获得首次鼠标焦点前可能只暴露空 AXGroup。
    /// 该坐标只负责把键盘焦点放进主输入框；发送仍走 CodexActionCoordinator 的完整核对链路。
    static let codex = VisualInputRecipe(
        bundleID: AccessibilityCodexDesktopAdapter.bundleIdentifier,
        inputX: 0.56,
        inputY: 0.91,
        submitX: 0.92,
        submitY: 0.91
    )

    static func recipe(for bundleID: String?) -> VisualInputRecipe? {
        switch bundleID {
        case weChat.bundleID: weChat
        case feishu.bundleID: feishu
        case codex.bundleID: codex
        default: nil
        }
    }

    /// 使用 CGWindowList 读取实际的屏幕窗口范围;始终取面积最大的普通窗口。
    /// Feishu 会额外创建一个 500×500 的无标题辅助窗口,不能误把它当成聊天主窗口。
    static func windowFrame(for processID: pid_t) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var largest: CGRect?
        for window in windows where (window[kCGWindowOwnerPID as String] as? pid_t) == processID
            && (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 300, height > 300 else { continue }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            if largest.map({ frame.width * frame.height > $0.width * $0.height }) ?? true {
                largest = frame
            }
        }
        return largest
    }

    static func focus(_ app: NSRunningApplication, recipe: VisualInputRecipe) -> VisualInputRecipe? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let frame = windowFrame(for: app.processIdentifier),
              topmostWindowOwner(at: recipe.inputPoint(in: frame)) == app.processIdentifier,
              click(at: recipe.inputPoint(in: frame)) else { return nil }
        var bound = recipe
        bound.expectedFrame = frame
        return bound
    }

    static func submit(_ app: NSRunningApplication, recipe: VisualInputRecipe) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let frame = windowFrame(for: app.processIdentifier),
              recipe.matches(frame),
              topmostWindowOwner(at: recipe.submitPoint(in: frame)) == app.processIdentifier else { return false }
        return click(at: recipe.submitPoint(in: frame))
    }

    /// CGWindowList 按前后层级排列；点击点第一个命中的普通窗口必须是目标进程，
    /// 避免应用声称自己是 frontmost、实际窗口仍被其他应用覆盖时把文字或发送操作落到错误应用。
    private static func topmostWindowOwner(at point: CGPoint) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  CGRect(x: x, y: y, width: width, height: height).contains(point) else { continue }
            return window[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    /// 微信 4.x 忽略发送给进程的合成鼠标事件，必须从 HID 层发送。
    private static func click(at point: CGPoint) -> Bool {
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
