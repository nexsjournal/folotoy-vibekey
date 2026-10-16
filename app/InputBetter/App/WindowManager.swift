import AppKit
import SwiftUI

/// 管理设置窗口、首次引导窗口和字幕记录窗口。app 是菜单栏应用(LSUIElement),打开窗口时需要主动激活。
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private unowned let app: AppState
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var transcriptWindow: NSWindow?

    init(app: AppState) {
        self.app = app
        super.init()
        // 切换界面语言时同步更新窗口标题。
        observeChanges({ [weak self] in _ = self?.app.language.locale }) { [weak self] in
            self?.settingsWindow?.title = String(localized: "InputBetter 设置", bundle: .l10n)
            self?.onboardingWindow?.title = String(localized: "欢迎使用 InputBetter", bundle: .l10n)
            self?.transcriptWindow?.title = String(localized: "字幕记录", bundle: .l10n)
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: String(localized: "InputBetter 设置", bundle: .l10n), size: NSSize(width: 940, height: 700),
                                        resizable: .init(minSize: NSSize(width: 820, height: 560), autosaveName: "InputBetterSettings"),
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

    /// 字幕记录窗口(字幕条 / 菜单 / 设置里的"字幕记录")。显示本次或刚结束的字幕会话,可以拷贝或保存成文件。
    func showTranscript() {
        if transcriptWindow == nil {
            transcriptWindow = makeWindow(title: String(localized: "字幕记录", bundle: .l10n), size: NSSize(width: 560, height: 620),
                                          resizable: .init(minSize: NSSize(width: 420, height: 360), autosaveName: "InputBetterTranscript"),
                                          content: LocalizedRoot(language: app.language) {
                                              TranscriptView(controller: self.app.subtitles) { [weak self] in self?.saveTranscriptFromWindow() }
                                          })
        }
        present(transcriptWindow)
    }

    /// 记录窗口里的"保存…":在窗口上弹出保存面板(表单),保存的是点击那一刻的记录。
    private func saveTranscriptFromWindow() {
        guard let window = transcriptWindow else { return }
        let transcript = app.subtitles.transcript
        Task {
            if await TranscriptSaver.save(transcript, in: window) { app.subtitles.markTranscriptSaved(transcript) }
        }
    }

    /// 可调整大小窗口的参数:最小尺寸,以及记住尺寸和位置用的名字。
    private struct Resizable {
        let minSize: NSSize
        let autosaveName: String
    }

    private func makeWindow(title: String, size: NSSize, resizable: Resizable? = nil, content: some View) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable != nil { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: content)
        // 可调整大小的窗口由用户决定尺寸,不让 SwiftUI 按内容最小尺寸收缩窗口。
        if resizable != nil { host.sizingOptions = [] }
        window.contentViewController = host
        window.setContentSize(size)
        window.center()
        // 可调整大小的窗口记住上次的尺寸和位置(必须在 center 之后设置,已保存的位置才会生效)。
        if let resizable {
            window.contentMinSize = resizable.minSize
            window.setFrameAutosaveName(resizable.autosaveName)
        }
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
