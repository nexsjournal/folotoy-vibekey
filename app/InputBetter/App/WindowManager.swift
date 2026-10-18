import AppKit
import SwiftUI

/// 管理设置窗口、首次引导窗口和字幕记录窗口。app 是菜单栏应用(LSUIElement),打开窗口时需要主动激活。
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private unowned let app: AppState
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var transcriptWindow: NSWindow?
    /// 设置窗口当前分类(可从外部直接打开某个分类)。
    private let settingsNavigation = SettingsNavigation()
    /// 字幕记录窗口的固定状态(固定在屏幕右侧、置顶)。
    private let transcriptPin = TranscriptPinController(autosaveName: WindowManager.transcriptAutosaveName)
    /// 字幕记录窗口当前的标签页(可从外部切换)。
    private let transcriptNavigation = TranscriptNavigation()
    private static let transcriptAutosaveName = "InputBetterTranscript"

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

    /// 打开设置窗口;传入分类时切换到该分类。
    /// - Parameters:
    ///   - configure: 同时弹出某个在线翻译服务的配置表单(字幕条 / 字幕记录「添加在线翻译服务」);
    ///   - useFor: 配置表单里「使用此服务」默认勾上的场景;
    ///   - systemTranslation: 同时弹出系统翻译的配置(语言包)。
    func showSettings(_ pane: SettingsView.Pane? = nil, configure provider: TranslationProvider? = nil,
                      useFor scenario: TranslationScenario? = nil, systemTranslation: Bool = false) {
        if let pane { settingsNavigation.pane = pane }
        if let provider { settingsNavigation.configure(provider, useFor: scenario) }
        if systemTranslation { settingsNavigation.configureSystemTranslation() }
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: String(localized: "InputBetter 设置", bundle: .l10n), size: NSSize(width: 940, height: 700),
                                        resizable: .init(minSize: NSSize(width: 820, height: 560), autosaveName: "InputBetterSettings"),
                                        content: LocalizedRoot(language: app.language) { SettingsView(app: self.app, navigation: self.settingsNavigation) })
        }
        present(settingsWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(title: String(localized: "欢迎使用 InputBetter", bundle: .l10n), size: NSSize(width: 680, height: 560),
                                          content: LocalizedRoot(language: app.language) {
                                              // 完成时只关窗口:finishOnboarding 统一在 windowWillClose 里调用一次
                                              // (用户直接关掉引导窗口也走同一条路)。
                                              OnboardingView(app: self.app) { [weak self] in
                                                  self?.onboardingWindow?.close()
                                              }
                                          })
        }
        present(onboardingWindow)
    }

    /// 字幕记录窗口(字幕条 / 菜单 / 设置里的"字幕记录")。显示本次或刚结束的字幕会话,可以拷贝或保存成文件。
    /// - Parameter activate: false 时只把窗口放到前面、不激活 app(从 Passport 结束字幕时,不抢用户当前应用的焦点)。
    func showTranscript(tab: TranscriptNavigation.Tab? = nil, activate: Bool = true) {
        if let tab { transcriptNavigation.tab = tab }
        if transcriptWindow == nil {
            transcriptWindow = makeWindow(title: String(localized: "字幕记录", bundle: .l10n), size: NSSize(width: 560, height: 620),
                                          resizable: .init(minSize: NSSize(width: 360, height: 360), autosaveName: Self.transcriptAutosaveName),
                                          content: LocalizedRoot(language: app.language) {
                                              TranscriptView(controller: self.app.subtitles, summarizer: self.app.summarizer,
                                                             translator: self.app.transcriptTranslator,
                                                             translation: self.app.translation,
                                                             catalog: self.app.llmModels,
                                                             settings: self.app.settings,
                                                             onOpenSettings: { [weak self] in self?.showSettings(.ai) },
                                                             // 「翻译设置…」打开 设置 › 实时字幕(字幕记录的翻译方式在那里);
                                                             // 配置某个在线服务时打开 设置 › 翻译服务 并弹出它的表单;保存后设为字幕的翻译方式
                                                             // (记录窗口默认跟随它,和从字幕条添加一致)。
                                                             onOpenTranslationSettings: { [weak self] provider in
                                                                 if let provider {
                                                                     self?.showSettings(.translation, configure: provider, useFor: .subtitles)
                                                                 } else {
                                                                     self?.showSettings(.subtitles)
                                                                 }
                                                             },
                                                             onOpenSystemTranslation: { [weak self] in
                                                                 self?.showSettings(.translation, systemTranslation: true)
                                                             },
                                                             pin: self.transcriptPin,
                                                             onSave: { [weak self] in self?.saveTranscriptFromWindow() },
                                                             navigation: self.transcriptNavigation)
                                          })
            transcriptPin.attach(transcriptWindow!)
        }
        if activate {
            present(transcriptWindow)
        } else {
            transcriptWindow?.orderFrontRegardless()
        }
        app.summarizer.setWindowVisible(true)
    }

    /// 字幕记录窗口是否正在显示(结束字幕时没显示才自动打开)。
    var isTranscriptVisible: Bool { transcriptWindow?.isVisible == true }

    /// 记录窗口里的"保存…":在窗口上弹出保存面板(表单),保存的是点击那一刻的记录。
    private func saveTranscriptFromWindow() {
        guard let window = transcriptWindow else { return }
        let transcript = app.subtitles.transcript
        Task {
            if await TranscriptSaver.save(transcript, summary: app.summarizer.plainText,
                                          includeTranslation: app.transcriptTranslator.showTranslations, in: window) {
                app.subtitles.markTranscriptSaved(transcript)
            }
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

    /// 把窗口放到最前并获得焦点。
    /// 菜单栏应用(LSUIElement)在 macOS 14 起的协作式激活下,单纯 activate() 偶尔会被系统拒绝:
    /// 窗口出现了却停在别的应用后面。按菜单栏应用的通行做法,显示窗口期间临时切成普通应用
    /// (出现在 Dock 和 ⌘Tab 里),激活后放到最前;这些窗口都关闭后再切回只在菜单栏(见 restoreMenuBarMode)。
    /// 放到下一轮事件循环执行:从菜单项点击时,等菜单关闭后再激活。
    private func present(_ window: NSWindow?) {
        guard let window else { return }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// 最后一个窗口关闭后切回只在菜单栏(最小化在 Dock 里的窗口还算打开,否则就没法还原了)。
    private func restoreMenuBarMode(closing: NSWindow) {
        let open = [settingsWindow, onboardingWindow, transcriptWindow].compactMap { $0 }
            .filter { $0 !== closing && ($0.isVisible || $0.isMiniaturized) }
        if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    /// 字幕记录窗口最小化时总结也暂停,还原后继续。
    func windowDidMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === transcriptWindow { app.summarizer.setWindowVisible(false) }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if notification.object as? NSWindow === transcriptWindow { app.summarizer.setWindowVisible(true) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        restoreMenuBarMode(closing: window)
        // 关闭字幕记录窗口:总结自动暂停。
        if window === transcriptWindow { app.summarizer.setWindowVisible(false) }
        if window === onboardingWindow {
            onboardingWindow = nil
            // 完成引导和直接关掉引导窗口都走这里(直接关掉也视为完成,避免下次启动又弹出)。
            if !app.settings.onboardingDone { app.finishOnboarding() }
        }
    }
}
