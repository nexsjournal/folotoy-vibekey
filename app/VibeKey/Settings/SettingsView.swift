import SwiftUI

/// 设置窗口:左侧分类,右侧内容。每个分类是独立的视图文件。
struct SettingsView: View {
    let app: AppState
    /// 当前分类(由 WindowManager 持有,外部可以直接打开某个分类,如字幕条里的"翻译设置")。
    @Bindable var navigation: SettingsNavigation

    enum Pane: String, CaseIterable, Identifiable {
        case general, dictation, subtitles, models, translation, ai, shortcuts, vocabulary, passport, vibe
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "通用", bundle: .l10n)
            case .dictation: String(localized: "听写", bundle: .l10n)
            case .models: String(localized: "识别模型", bundle: .l10n)
            case .shortcuts: String(localized: "快捷键", bundle: .l10n)
            case .translation: String(localized: "翻译服务", bundle: .l10n)
            case .ai: String(localized: "AI 服务", bundle: .l10n)
            case .subtitles: String(localized: "实时字幕", bundle: .l10n)
            case .passport: String(localized: "Passport", bundle: .l10n)
            case .vibe: String(localized: "Vibe Coding", bundle: .l10n)
            case .vocabulary: String(localized: "词汇表", bundle: .l10n)
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .dictation: "mic.fill"
            case .models: "waveform"
            case .shortcuts: "command"
            case .translation: "translate"
            case .ai: "sparkles"
            case .subtitles: "captions.bubble.fill"
            case .passport: "keyboard.badge.ellipsis"
            case .vibe: "chevron.left.forwardslash.chevron.right"
            case .vocabulary: "character.book.closed.fill"
            }
        }
    }

    private var pane: SettingsView.Pane { navigation.pane }

    var body: some View {
        HStack(spacing: 0) {
            // 固定宽度的侧边栏(NavigationSplitView 在自建窗口里不认列宽,英文标题会被截断)。
            List(Pane.allCases, selection: $navigation.pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    GradientIcon(symbol: pane.symbol, size: 22)
                }
                .tag(pane)
            }
            .listStyle(.sidebar)
            .padding(.top, 28)
            .frame(width: 236)
            .background(.regularMaterial)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(pane.title)
                        .font(.system(size: 22, weight: .bold))
                        .padding(.top, 6)
                    detail
                }
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { app.permissions.startPolling() }
        .onDisappear { app.permissions.stopPolling() }
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralPane(app: app)
        case .dictation: DictationPane(app: app, navigation: navigation)
        case .models: ModelsPane(app: app)
        case .shortcuts: ShortcutsPane(app: app)
        case .translation: TranslationPane(app: app, navigation: navigation)
        case .ai: AIPane(app: app, navigation: navigation)
        case .subtitles: SubtitlesPane(app: app, navigation: navigation)
        case .passport: PassportPane(app: app)
        case .vibe: VibePane(app: app)
        case .vocabulary: VocabularyPane(settings: app.settings)
        }
    }
}

/// 设置页里带标题的一组内容。
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            content
            if let footer { Hint(footer).padding(.leading, 2) }
        }
        .padding(.top, DS.Space.l)
    }
}

/// 卡片里的一行:左侧标题(可带说明),右侧控件。
struct SettingRow<Control: View>: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    /// 已经本地化好的说明文字(来自枚举 / 模型,用 String(localized:) 生成)。
    var detailText: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                if let detailText { Text(verbatim: detailText).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: DS.Space.m)
            // 右侧控件统一靠右对齐,按内容宽度显示。
            control
                .frame(alignment: .trailing)
        }
        .frame(minHeight: 26)
    }
}

/// 设置窗口当前显示的分类。
@MainActor @Observable
final class SettingsNavigation {
    var pane: SettingsView.Pane = SettingsNavigation.initialPane
    /// 正在配置的在线翻译服务(翻译页弹出配置表单;字幕条「添加在线翻译服务」会直接设置它)。
    var configuringProvider: TranslationProvider? = SettingsNavigation.initialProvider
    /// 从哪个场景的方式菜单进来配置(配置表单里「使用此服务」默认勾上这个场景)。
    var providerUse: TranslationScenario?
    /// 显示系统翻译的配置(语言包)。
    var showingSystemTranslation = false

    /// 去 翻译服务 页配置某个在线服务(从任何场景的方式菜单「添加在线翻译服务」进来,都走这里)。
    func configure(_ provider: TranslationProvider, useFor scenario: TranslationScenario?) {
        pane = .translation
        providerUse = scenario
        configuringProvider = provider
    }

    /// 去 翻译服务 页打开系统翻译的配置(下载语言包)。
    func configureSystemTranslation() {
        pane = .translation
        showingSystemTranslation = true
    }

    /// 调试用:环境变量 IB_SETTINGS_PANE=<rawValue> 打开指定分类。
    private static var initialPane: SettingsView.Pane {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["IB_SETTINGS_PANE"], let p = SettingsView.Pane(rawValue: raw) { return p }
        #endif
        return .general
    }

    /// 调试用:IB_TRANSLATE_CONFIG=<TranslationProvider.rawValue>(配合 IB_SETTINGS_PANE=translation)直接弹出配置表单。
    private static var initialProvider: TranslationProvider? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["IB_TRANSLATE_CONFIG"] { return TranslationProvider(rawValue: raw) }
        #endif
        return nil
    }
}
