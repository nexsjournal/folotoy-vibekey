import SwiftUI

/// 某个场景(实时字幕 / 听写)的「翻译方式」一行:右侧是和字幕条同一个方式菜单(TranslationMethodMenuItems);
/// 当前方式不可用时用橙色说明原因。设置 › 听写、设置 › 实时字幕 共用。
/// 菜单里「添加在线翻译服务」「下载语言包」「配置 AI 服务」都跳到对应的设置页并直接打开配置。
struct TranslationMethodSettingRow: View {
    let app: AppState
    let navigation: SettingsNavigation
    let scenario: TranslationScenario
    @Binding var selection: TranslationMethod
    /// 按哪个目标语言判断系统翻译能不能用。
    let target: TargetLanguage

    var body: some View {
        let translation = app.translation
        let reason = translation.unavailableReason(selection, target: target)
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("翻译方式").font(.system(size: 13))
                if let reason {
                    Label { Text(verbatim: String(localized: "\(reason)，在右侧菜单里配置或换一种方式", bundle: .l10n)) }
                        icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.system(size: 11.5)).foregroundStyle(DS.warning)
                } else {
                    Text(verbatim: selection.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DS.Space.m)
            Menu {
                TranslationMethodMenuItems(current: selection, target: target, translation: translation, catalog: app.llmModels,
                                           settings: app.settings,
                                           onSelect: { selection = $0 },
                                           onConfigure: { navigation.configure($0, useFor: scenario) },
                                           onConfigureSystem: { navigation.configureSystemTranslation() },
                                           onConfigureLLM: { navigation.pane = .ai },
                                           onSettings: nil)  // 已经在设置里了,不需要再跳
            } label: {
                Text(verbatim: selection.shortLabel(model: translation.modelName(selection)))
            }
            .fixedSize()
            .accessibilityLabel(scenario == .subtitles ? "实时字幕的翻译方式" : "听写的翻译方式")
        }
        .frame(minHeight: 26)
    }
}

/// 「翻译成」一行(选「自动」时说明方向)。
struct TargetLanguageSettingRow: View {
    var title: LocalizedStringKey = "翻译成"
    /// 不是「自动」时的说明。
    var detail: String?
    @Binding var selection: TargetLanguage

    var body: some View {
        SettingRow(title: title,
                   detailText: selection == .auto ? String(localized: "自动：\(TargetLanguage.autoSummary)", bundle: .l10n) : detail) {
            Picker("", selection: $selection) {
                ForEach(TargetLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }
}

/// 翻译的两种场景。
enum TranslationScenario: Equatable {
    case subtitles, dictation
}

extension View {
    /// 设置页说明文字里的应用内链接(`inputbetter-settings://<pane>`)跳到对应的设置页,
    /// 如「按住[快捷键](inputbetter-settings://shortcuts)…」点「快捷键」跳到快捷键页。
    func settingsLinks(_ navigation: SettingsNavigation) -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "inputbetter-settings", let pane = url.host().flatMap(SettingsView.Pane.init(rawValue:)) else {
                return .systemAction
            }
            navigation.pane = pane
            return .handled
        })
    }
}
