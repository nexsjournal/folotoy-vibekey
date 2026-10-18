import AppKit
import KeyboardShortcuts

/// 菜单栏图标与胶囊 ⌃ 按钮共用的快捷菜单。每次打开时按当前状态重新生成。
@MainActor
final class MenuBuilder {
    private unowned let app: AppState

    init(app: AppState) {
        self.app = app
    }

    func build() -> NSMenu {
        let menu = NSMenu()
        let settings = app.settings

        let model = ModelCatalog.model(settings.dictationModelID)
        menu.addItem(.header("InputBetter · " + (model?.name ?? String(localized: "未选择模型", bundle: .l10n))))

        let dictating = app.dictation.phase.isBusy
        menu.addItem(ActionItem(dictating ? String(localized: "结束听写", bundle: .l10n) : String(localized: "开始听写", bundle: .l10n), key: app.hotkeys.dictateDescription) { [app] in
            app.dictation.toggle()
        })
        menu.addItem(subtitleMenu())
        menu.addItem(.separator())

        menu.addItem(submenu(String(localized: "识别模型", bundle: .l10n), items: ModelCatalog.all.map { info in
            let installed = app.models.isInstalled(info.id)
            let item = ActionItem(info.name, checked: settings.dictationModelID == info.id) { [app] in
                app.settings.dictationModelID = info.id
            }
            item.isEnabled = installed
            if !installed {
                item.title += info.cloudProvider == nil ? String(localized: "（未下载）", bundle: .l10n) : String(localized: "（未配置）", bundle: .l10n)
            }
            return item
        }))
        menu.addItem(submenu(String(localized: "麦克风", bundle: .l10n), items: micItems()))
        menu.addItem(submenu(String(localized: "识别语言", bundle: .l10n), items: SpeechLanguage.allCases.map { lang in
            ActionItem(lang.title, checked: settings.language == lang) { [app] in app.settings.language = lang }
        }))

        // 写明是听写的润色(字幕不润色);没配置 AI 服务时说明原因,点了打开 AI 服务设置。
        let polish = settings.llmConfigured
            ? ActionItem(String(localized: "听写后 AI 润色", bundle: .l10n), checked: settings.polishEnabled) { [app] in app.settings.polishEnabled.toggle() }
            : ActionItem(String(localized: "听写后 AI 润色（需要配置 AI 服务）…", bundle: .l10n)) { [app] in app.windows.showSettings(.ai) }
        menu.addItem(polish)
        if settings.subtitleLocked {
            menu.addItem(ActionItem(String(localized: "解锁字幕条", bundle: .l10n)) { [app] in app.settings.subtitleLocked = false })
        }
        // 常驻:状态条被拖到看不见的地方(或换了显示器)时总能找回来。
        menu.addItem(ActionItem(String(localized: "状态条回到底部中央", bundle: .l10n), key: app.hotkeys.resetPillPositionDescription) { [app] in
            app.resetPillPosition()
        })

        menu.addItem(.separator())
        menu.addItem(.header(deviceStatus()))
        menu.addItem(ActionItem(String(localized: "设置…", bundle: .l10n), key: "⌘,") { [app] in app.windows.showSettings() })
        if let updates = app.updates {
            menu.addItem(ActionItem(String(localized: "检查更新…", bundle: .l10n)) { updates.checkNow() })
        }
        menu.addItem(ActionItem(String(localized: "退出 InputBetter", bundle: .l10n), key: "⌘Q") { NSApp.terminate(nil) })
        return menu
    }

    // MARK: - 子菜单

    private func subtitleMenu() -> NSMenuItem {
        var items: [NSMenuItem] = []
        if app.subtitles.isRunning {
            let collapsed = app.captionsCollapsed
            items.append(ActionItem(collapsed ? String(localized: "展开字幕条", bundle: .l10n) : String(localized: "收起字幕条", bundle: .l10n)) { [app] in
                app.setCaptionsCollapsed(!collapsed)
            })
            items.append(ActionItem(String(localized: "结束字幕（\(app.subtitles.appName)）", bundle: .l10n)) { [app] in app.stopCaptions() })
            items.append(.separator())
            items += translationItems()
        }
        // 字幕记录:运行中或刚结束(记录还在内存里)时可以查看。
        if app.subtitles.isRunning || !app.subtitles.transcript.isEmpty {
            items.append(ActionItem(String(localized: "字幕记录…", bundle: .l10n)) { [app] in app.windows.showTranscript() })
            items.append(.separator())
        }
        items += captionAppItems { [app] audioApp in app.startCaptions(audioApp) }
        return submenu(String(localized: "实时字幕", bundle: .l10n), items: items)
    }

    /// 本场字幕的翻译(和字幕条「译」标签是同一个开关):字幕条锁定(鼠标穿透)后标题栏出不来,从菜单里也要能开关、换语言、换方式。
    private func translationItems() -> [NSMenuItem] {
        let subtitles = app.subtitles, settings = app.settings, translation = app.translation
        let toggle = ActionItem(String(localized: "翻译本场字幕", bundle: .l10n), checked: subtitles.translationEnabled) { [app] in
            app.subtitles.toggleTranslation()
        }
        toggle.isEnabled = subtitles.translationEnabled || translation.isAvailable
        if !translation.isAvailable, let reason = translation.unavailableReason(settings.subtitleTranslationMethod) {
            toggle.title += "（\(reason)）"
        }
        let languages = TargetLanguage.allCases.map { language in
            ActionItem(language == .auto ? "\(language.title)（\(TargetLanguage.autoSummary)）" : language.title,
                       checked: settings.subtitleTarget == language) { [app] in
                app.settings.subtitleTarget = language
                app.subtitles.setTranslationEnabled(true)
            }
        }
        var methods: [TranslationMethod] = [.system] + app.translationProviders.configured.map { .provider($0) }
        if settings.llmConfigured { methods.append(.llm(model: "")) }
        let methodItems = methods.map { method in
            let item = ActionItem(method.shortLabel(model: translation.modelName(method)),
                                  checked: settings.subtitleTranslationMethod.sameKind(as: method)) { [app] in
                app.settings.subtitleTranslationMethod = method
            }
            if let reason = translation.unavailableReason(method) {
                item.title += "（\(reason)）"
                item.isEnabled = false
            }
            return item
        }
        return [toggle,
                submenu(String(localized: "翻译成", bundle: .l10n), items: languages),
                submenu(String(localized: "翻译方式", bundle: .l10n), items: methodItems)]
    }

    /// 字幕来源选择菜单(胶囊 ◉、开关字幕快捷键共用):列出正在运行的应用,正在出声的排在前面。
    func captionAppsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.header(String(localized: "为哪个应用生成字幕？", bundle: .l10n)))
        captionAppItems { [app] audioApp in app.startCaptions(audioApp) }.forEach(menu.addItem)
        return menu
    }

    private func captionAppItems(onPick: @escaping (AudioApp) -> Void) -> [NSMenuItem] {
        let apps = AudioProcesses.runningApps()
        if apps.isEmpty { return [.header(String(localized: "没有正在运行的应用", bundle: .l10n))] }
        return apps.map { audioApp in
            let item = ActionItem(audioApp.name, checked: app.subtitles.isRunning && app.subtitles.appBundleID == audioApp.bundleID) {
                onPick(audioApp)
            }
            item.image = NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: audioApp.bundleID)?.path ?? "")
            item.image?.size = NSSize(width: 16, height: 16)
            if audioApp.isPlaying { item.title += String(localized: "  ● 正在播放", bundle: .l10n) }
            return item
        }
    }

    private func micItems() -> [NSMenuItem] {
        let settings = app.settings
        var items: [NSMenuItem] = [
            ActionItem(String(localized: "系统默认（\(app.inputDevices.defaultDeviceName)）", bundle: .l10n), checked: settings.micID.isEmpty) { [app] in
                app.settings.micID = ""
            },
        ]
        for device in app.inputDevices.devices {
            items.append(ActionItem(device.name, checked: settings.micID == device.uid) { [app] in
                app.settings.micID = device.uid
            })
        }
        let passport = ActionItem(String(localized: "Passport 麦克风", bundle: .l10n), checked: settings.micID == AppSettings.passportMicID) { [app] in
            app.settings.micID = AppSettings.passportMicID
        }
        passport.isEnabled = app.deviceLink.connection != .disconnected
        items.append(.separator())
        items.append(passport)
        return items
    }

    private func deviceStatus() -> String {
        let link = app.deviceLink
        switch link.connection {
        case .disconnected: return String(localized: "Passport 未连接", bundle: .l10n)
        case .usb, .ble:
            let via = link.connection == .usb ? "USB" : String(localized: "蓝牙", bundle: .l10n)
            let battery = link.batteryPercent.map { " · \($0)%" } ?? ""
            return String(localized: "Passport 已连接（\(via)）\(battery)", bundle: .l10n)
        }
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach(sub.addItem)
        item.submenu = sub
        return item
    }
}

/// 用闭包处理点击的菜单项。处理器对象存放在 representedObject 里,随菜单项一起释放。
@MainActor
func ActionItem(_ title: String, key: String? = nil, checked: Bool = false, handler: @escaping () -> Void) -> NSMenuItem {
    let target = MenuHandler(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuHandler.fire), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    item.state = checked ? .on : .off
    if let key, !key.isEmpty {
        // 只作提示显示,真正的快捷键由 HotkeyManager 处理。
        let attributed = NSMutableAttributedString(string: title)
        attributed.append(NSAttributedString(string: "    \(key)", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
        item.attributedTitle = attributed
    }
    return item
}

private final class MenuHandler: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

extension NSMenuItem {
    /// 不可点击的说明行。
    static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
