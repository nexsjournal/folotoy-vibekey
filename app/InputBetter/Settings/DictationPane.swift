import KeyboardShortcuts
import SwiftUI

/// 设置 › 听写:说完之后对文字做什么(AI 润色、翻译)。和听写有关的行为集中在这里,用户不用在几个页面之间找:
/// - AI 润色:开关 + 模型(接口和 Key 在 设置 › AI 服务 里配置一次,这里只选模型);
/// - 听写翻译:翻译方式(和字幕条同一个方式菜单)、翻译成;快捷键在说明文字里链接到快捷键页。
/// 听写用的识别模型在「识别模型」页,麦克风和识别语言在「通用」页。
struct DictationPane: View {
    let app: AppState
    let navigation: SettingsNavigation

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "AI 润色", footer: "按住「听写」快捷键说话，松开后先润色再输入。AI 会参考[词汇表](inputbetter-settings://vocabulary)纠正专有名词。") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        SettingRow(title: "听写后 AI 润色",
                                   detail: settings.llmConfigured ? "去掉口水词，补全标点，修正同音错字" : "需要先配置 AI 服务") {
                            Toggle("", isOn: $settings.polishEnabled).labelsHidden().toggleStyle(.switch)
                                .disabled(!settings.llmConfigured)
                        }
                        Divider()
                        if settings.llmConfigured {
                            SettingRow(title: "润色模型", detail: "模型越强，修正得越准；越小越快") {
                                Menu {
                                    LLMModelMenuItems(selected: settings.polishModel, catalog: app.llmModels, settings: settings) {
                                        settings.polishModel = $0
                                    }
                                } label: {
                                    Text(verbatim: settings.polishModel.isEmpty
                                         ? String(localized: "默认模型（\(settings.llmModel)）", bundle: .l10n) : settings.polishModel)
                                }
                                .fixedSize()
                            }
                            .disabled(!settings.polishEnabled)
                        } else {
                            SettingRow(title: "AI 服务", detail: "支持 OpenAI、DeepSeek、通义千问等所有 OpenAI 兼容接口") {
                                Button("配置 AI 服务…") { navigation.pane = .ai }.buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }
            }
            SettingsSection(title: "听写翻译", footer: translateFooter) {
                Card {
                    VStack(spacing: DS.Space.m) {
                        TranslationMethodSettingRow(app: app, navigation: navigation, scenario: .dictation,
                                                    selection: $settings.dictationTranslationMethod, target: settings.translateTarget)
                        Divider()
                        TargetLanguageSettingRow(selection: $settings.translateTarget)
                    }
                }
            }
        }
        .settingsLinks(navigation)
        .onAppear { app.llmModels.loadIfNeeded() }
    }

    /// 说明里带快捷键;点「快捷键」跳到快捷键页修改。
    private var translateFooter: LocalizedStringKey {
        let shortcut = KeyboardShortcuts.getShortcut(for: .translateDictate)?.description ?? String(localized: "未设置", bundle: .l10n)
        return "按住「翻译听写」[快捷键](inputbetter-settings://shortcuts)（\(shortcut)）说话，松开后把译文输入到光标处。"
    }
}
