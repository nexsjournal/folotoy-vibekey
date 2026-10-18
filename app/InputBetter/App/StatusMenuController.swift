import AppKit

/// 菜单栏图标及其菜单。
/// 按 AppKit 文档的标准做法把菜单常驻挂在 `NSStatusItem.menu` 上,由系统负责弹出位置、高亮和键盘导航;
/// 每次打开前在 `menuNeedsUpdate` 里按当前状态重新生成内容(MenuBuilder.build)。
/// 已知系统问题(macOS 27,多显示器):另一块屏的菜单栏放不下图标(收进 `<<` 溢出区)时,在那块屏上点一下,
/// 系统会把状态项窗口停到那块屏边缘外,回到原屏点图标时窗口位置没有挪回来,菜单按过期位置弹出而偏离图标。
/// 同样收在溢出区的其他应用也会这样(实测 Pwdx),不在 app 里自行计算位置绕开。
/// 只在主线程使用(菜单和状态项都是 AppKit 对象)。
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let build: () -> NSMenu

    /// `build`:生成菜单内容(和状态条 ⌃ 按钮共用 MenuBuilder.build)。
    init(build: @escaping () -> NSMenu) {
        self.build = build
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "InputBetter")
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 菜单打开前调用:把新生成的菜单项搬进常驻菜单(菜单项不能同时属于两个菜单,先从临时菜单里移除)。
    /// NSMenuDelegate 在 SDK 里是 @MainActor 协议,系统在主线程回调。
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = build()
        let items = fresh.items
        fresh.removeAllItems()
        menu.removeAllItems()
        items.forEach(menu.addItem)
    }
}
