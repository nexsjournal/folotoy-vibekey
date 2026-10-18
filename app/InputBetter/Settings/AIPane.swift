import SwiftUI

/// 设置 › AI 服务:只负责 LLM 接口的连接(地址、Key、默认模型),一处配置、各功能共用。
/// 下方列出哪些功能在用它、用的哪个模型,点「前往」到该功能自己的设置里改(各功能可以各选模型)。
struct AIPane: View {
    let app: AppState
    let navigation: SettingsNavigation

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "连接", footer: "支持所有 OpenAI 兼容接口（OpenAI、DeepSeek、通义千问、OpenRouter、Ollama 等）。API Key 只保存在本机配置文件中（仅当前用户可读）。这里的模型是默认模型，各功能可以另选。") {
                LLMConfigForm(settings: settings, catalog: app.llmModels)
            }
            SettingsSection(title: "使用 AI 服务的功能") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        usage("听写后 AI 润色",
                              status: settings.polishEnabled ? model(settings.polishModel) : String(localized: "未开启", bundle: .l10n),
                              pane: .dictation)
                        Divider()
                        usage("实时字幕翻译", status: translationStatus(settings.subtitleTranslationMethod), pane: .subtitles)
                        Divider()
                        usage("听写翻译", status: translationStatus(settings.dictationTranslationMethod), pane: .dictation)
                        Divider()
                        SettingRow(title: "字幕总结",
                                   detailText: String(localized: "在字幕记录窗口的「总结」页使用 · \(model(settings.summaryModel))", bundle: .l10n)) {
                            EmptyView()
                        }
                    }
                }
                .disabled(!settings.llmConfigured)
            }
        }
    }

    private func usage(_ title: LocalizedStringKey, status: String, pane: SettingsView.Pane) -> some View {
        SettingRow(title: title, detailText: status) {
            Button("前往") { navigation.pane = pane }.buttonStyle(SecondaryButtonStyle())
        }
    }

    /// 模型名:空 = 默认模型。
    private func model(_ name: String) -> String {
        name.isEmpty ? String(localized: "默认模型（\(app.settings.llmModel)）", bundle: .l10n) : name
    }

    private func translationStatus(_ method: TranslationMethod) -> String {
        guard case .llm(let name) = method else {
            return String(localized: "未使用 AI（当前：\(method.shortLabel(model: nil))）", bundle: .l10n)
        }
        return model(name)
    }
}
