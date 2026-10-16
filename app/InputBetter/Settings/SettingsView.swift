import SwiftUI

/// 设置窗口:左侧分类,右侧内容。每个分类是独立的视图文件。
struct SettingsView: View {
    let app: AppState

    enum Pane: String, CaseIterable, Identifiable {
        case general, models, shortcuts, ai, subtitles, passport, vibe, vocabulary
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "通用", bundle: .l10n)
            case .models: String(localized: "识别模型", bundle: .l10n)
            case .shortcuts: String(localized: "快捷键", bundle: .l10n)
            case .ai: String(localized: "AI 润色与翻译", bundle: .l10n)
            case .subtitles: String(localized: "实时字幕", bundle: .l10n)
            case .passport: String(localized: "Passport", bundle: .l10n)
            case .vibe: String(localized: "Vibe Coding", bundle: .l10n)
            case .vocabulary: String(localized: "词汇表", bundle: .l10n)
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .models: "waveform"
            case .shortcuts: "command"
            case .ai: "sparkles"
            case .subtitles: "captions.bubble.fill"
            case .passport: "keyboard.badge.ellipsis"
            case .vibe: "chevron.left.forwardslash.chevron.right"
            case .vocabulary: "character.book.closed.fill"
            }
        }
    }

    @State private var pane: Pane = Self.initialPane

    /// 调试用:环境变量 IB_SETTINGS_PANE=<rawValue> 打开指定分类。
    private static var initialPane: Pane {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["IB_SETTINGS_PANE"], let p = Pane(rawValue: raw) { return p }
        #endif
        return .general
    }

    var body: some View {
        HStack(spacing: 0) {
            // 固定宽度的侧边栏(NavigationSplitView 在自建窗口里不认列宽,英文标题会被截断)。
            List(Pane.allCases, selection: $pane) { pane in
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
        case .models: ModelsPane(app: app)
        case .shortcuts: ShortcutsPane(app: app)
        case .ai: AIPane(settings: app.settings)
        case .subtitles: SubtitlesPane(app: app)
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
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: DS.Space.m)
            // 右侧控件统一靠右对齐,按内容宽度显示。
            control
                .frame(alignment: .trailing)
        }
        .frame(minHeight: 26)
    }
}
