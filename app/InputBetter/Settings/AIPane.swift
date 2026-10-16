import SwiftUI

/// AI:LLM 连接、润色开关、翻译目标语言。
struct AIPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "LLM 服务", footer: "支持所有 OpenAI 兼容接口。API Key 只保存在本机配置文件中（仅当前用户可读）。") {
                LLMConfigForm(settings: settings)
            }
            SettingsSection(title: "用途") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        SettingRow(title: "听写后自动润色", detail: "去掉口水词，补全标点，修正同音错字") {
                            Toggle("", isOn: $settings.polishEnabled).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        SettingRow(title: "翻译听写的目标语言") {
                            Picker("", selection: $settings.translateTarget) {
                                ForEach(TargetLanguage.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        Divider()
                        SettingRow(title: "字幕翻译的目标语言") {
                            Picker("", selection: $settings.subtitleTarget) {
                                ForEach(TargetLanguage.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
                .disabled(!settings.llmConfigured)
            }
        }
    }
}
