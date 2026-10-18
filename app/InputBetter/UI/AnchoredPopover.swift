import AppKit
import SwiftUI

/// 挂在某个视图上的系统 popover(NSPopover,带小三角、点外面自动关闭),内容是 SwiftUI 视图。
/// 比 SwiftUI 自带的 `.popover` 多了外观控制:状态条上的提示要用深色外观(和字幕条一致),系统 popover 默认跟随系统外观。
/// 用法:`view.anchoredPopover(isPresented:, appearance: .darkAqua) { content }`。
/// - 关闭(点外面、Esc、代码里把 isPresented 置 false)后 isPresented 回到 false;
/// - 挂载视图是 SwiftUI 托管视图(翻转坐标),`preferredEdge` 已换算成"视觉上在上方"。
struct AnchoredPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let appearance: NSAppearance.Name
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = { isPresented = false }
        if isPresented {
            if let popover = coordinator.popover {
                // 内容随状态变化(如勾选「不再询问」),每次更新刷新根视图。
                (popover.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(content())
                return
            }
            let host = NSHostingController(rootView: AnyView(content()))
            host.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.appearance = NSAppearance(named: appearance)
            popover.contentViewController = host
            popover.delegate = coordinator
            coordinator.popover = popover
            // 托管视图是翻转坐标(y 向下),minY 才是视觉上的顶边:气泡出现在按钮上方、三角朝下指着按钮。
            // 视图可能还没进窗口(首帧),推迟到下一轮再显示。
            DispatchQueue.main.async {
                guard view.window != nil, coordinator.popover === popover, !popover.isShown else { return }
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
            }
        } else if let popover = coordinator.popover {
            coordinator.popover = nil
            popover.performClose(nil)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.onClose = nil
        coordinator.popover?.performClose(nil)
        coordinator.popover = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var onClose: (() -> Void)?

        func popoverDidClose(_ notification: Notification) {
            guard let closed = notification.object as? NSPopover, closed === popover else { return }
            popover = nil
            onClose?()
        }
    }
}

extension View {
    /// 在这个视图上方挂一个系统 popover(见 AnchoredPopover)。
    func anchoredPopover<Content: View>(isPresented: Binding<Bool>, appearance: NSAppearance.Name = .darkAqua,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        background(AnchoredPopover(isPresented: isPresented, appearance: appearance, content: content))
    }
}
