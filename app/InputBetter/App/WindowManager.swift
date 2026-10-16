import AppKit
import SwiftUI

/// 管理设置窗口与首次引导窗口。app 是菜单栏应用(LSUIElement),打开窗口时需要主动激活。
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private unowned let app: AppState
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    init(app: AppState) {
        self.app = app
        super.init()
        // 切换界面语言时同步更新窗口标题。
        observeChanges({ [weak self] in _ = self?.app.language.locale }) { [weak self] in
            self?.settingsWindow?.title = String(localized: "InputBetter 设置", bundle: .l10n)
            self?.onboardingWindow?.title = String(localized: "欢迎使用 InputBetter", bundle: .l10n)
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: String(localized: "InputBetter 设置", bundle: .l10n), size: NSSize(width: 940, height: 700), resizable: true,
                                        content: LocalizedRoot(language: app.language) { SettingsView(app: self.app) })
        }
        present(settingsWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(title: String(localized: "欢迎使用 InputBetter", bundle: .l10n), size: NSSize(width: 680, height: 560),
                                          content: LocalizedRoot(language: app.language) {
                                              OnboardingView(app: self.app) { [weak self] in
                                                  self?.onboardingWindow?.close()
                                                  self?.app.finishOnboarding()
                                              }
                                          })
        }
        present(onboardingWindow)
    }

    private func makeWindow(title: String, size: NSSize, resizable: Bool = false, content: some View) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: content)
        // 可调整大小的窗口由用户决定尺寸,不让 SwiftUI 按内容最小尺寸收缩窗口。
        if resizable { host.sizingOptions = [] }
        window.contentViewController = host
        window.setContentSize(size)
        // 设置窗口可以调整大小,并记住上次的尺寸和位置。
        if resizable {
            window.contentMinSize = NSSize(width: 820, height: 560)
            window.setFrameAutosaveName("InputBetterSettings")
        }
        window.center()
        window.delegate = self
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            onboardingWindow = nil
            // 直接关掉引导窗口也视为完成,避免下次启动又弹出。
            if !app.settings.onboardingDone { app.finishOnboarding() }
        }
    }
}
