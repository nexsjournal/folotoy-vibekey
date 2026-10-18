import SwiftUI

/// 设置 › 实时字幕:和字幕有关的设置集中在这里——识别(字幕用的模型)、显示(字号、行数、锁定)、
/// 翻译(方式、默认翻译成、边说边译)、字幕记录。模型的下载和云端服务配置在「识别模型」页。
/// 开始字幕在状态条 ◉ / 菜单栏「实时字幕」/ 快捷键里选应用(那里能看到哪个应用正在出声),设置页不重复放应用列表。
/// 翻译的开关不在这里:每场字幕默认不翻译,点字幕条上的「译」就翻译成「默认翻译成」的语言;翻译服务的配置在「翻译服务」页。
struct SubtitlesPane: View {
    let app: AppState
    let navigation: SettingsNavigation

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "识别", footer: "Apple Speech 与云端流式服务的字幕延迟最低；其他本地模型按句识别，准确率更高。模型在[识别模型](inputbetter-settings://models)里下载，云端服务也在那里配置。") {
                Card {
                    SettingRow(title: "字幕使用的模型") { modelPicker(selection: $settings.subtitleModelID) }
                }
            }
            SettingsSection(title: "显示") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        fontRow("译文字号", value: $settings.subtitleTranslationFontSize)
                        Divider()
                        fontRow("原文字号", value: $settings.subtitleSourceFontSize)
                        Divider()
                        SettingRow(title: "译文行数", detail: "行数多，一句译文在屏幕上停留得更久，更容易读完") {
                            Picker("", selection: $settings.subtitleTranslationLines) {
                                ForEach(2...5, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        Divider()
                        SettingRow(title: "翻译时原文行数", detail: "不显示时只显示译文，阅读最轻松") {
                            Picker("", selection: $settings.subtitleSourceLines) {
                                Text("不显示").tag(0)
                                ForEach(1...3, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        Divider()
                        SettingRow(title: "锁定字幕条", detail: "锁定后鼠标点击会穿透，不挡视频控件") {
                            Toggle("", isOn: $settings.subtitleLocked).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
            }
            SettingsSection(title: "翻译", footer: "每场字幕默认不翻译：点字幕条上的「译」开始翻译，再点一次关闭；「译」旁的箭头可以换语言。字幕条上的翻译方式菜单改的也是这里。在线服务和语言包在[翻译服务](inputbetter-settings://translation)里配置。") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        TranslationMethodSettingRow(app: app, navigation: navigation, scenario: .subtitles,
                                                    selection: $settings.subtitleTranslationMethod, target: settings.subtitleTarget)
                        Divider()
                        TargetLanguageSettingRow(title: "默认翻译成",
                                                 detail: String(localized: "点字幕条上的「译」就翻译成这个语言", bundle: .l10n),
                                                 selection: $settings.subtitleTarget)
                        Divider()
                        SettingRow(title: "边说边译", detailText: liveDraftDetail(for: settings.subtitleTranslationMethod)) {
                            Toggle("", isOn: $settings.translationLiveDraft).labelsHidden().toggleStyle(.switch)
                                .disabled(settings.subtitleTranslationMethod.isLLM)
                        }
                    }
                }
            }
            SettingsSection(title: "字幕记录", footer: "InputBetter 不保存字幕历史：记录只在内存中，下次开始字幕或退出后清除。结束字幕后会打开字幕记录窗口，可以在那里查看、翻译、总结和保存；字幕进行中可以点字幕条上的 \(Image(systemName: "text.page")) 打开。") {
                Card {
                    SettingRow(title: "结束字幕前确认") {
                        Toggle("", isOn: $settings.confirmStopCaptions).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
        .settingsLinks(navigation)

    }

    /// 「边说边译」的说明按方式写清代价:在线服务是按字符计费的,反复重翻尾巴的额度约是整句翻译的 2–3 倍。
    private func liveDraftDetail(for method: TranslationMethod) -> String {
        switch method {
        case .llm: String(localized: "AI 翻译会在整句说完后逐字出现，不支持边说边译", bundle: .l10n)
        case .provider: String(localized: "一句话还没说完就先给出暂定译文（略暗），说完后换成整句译文。在线服务下消耗的额度约为整句翻译的 2–3 倍", bundle: .l10n)
        case .system: String(localized: "一句话还没说完就先给出暂定译文（略暗），说完后换成整句译文。系统翻译在本机完成，没有额外开销", bundle: .l10n)
        }
    }

    /// 字幕用的识别模型:默认与听写相同,也可以单独选一个已安装(或已配置的云端)模型。
    private func modelPicker(selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            Text("与听写相同").tag("")
            ForEach(ModelCatalog.all.filter { app.models.isInstalled($0.id) }) { Text($0.name).tag($0.id) }
            // 选中的模型已删除 / 云端配置已移除:仍显示出来并标明不可用,不让选择框变空白。
            let selected = selection.wrappedValue
            if !selected.isEmpty, !app.models.isInstalled(selected) {
                Text("\(ModelCatalog.model(selected)?.name ?? selected)（不可用）").tag(selected)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func fontRow(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        SettingRow(title: title) {
            HStack {
                Slider(value: value, in: AppSettings.subtitleFontRange, step: 1).frame(width: 180)
                Text(verbatim: "\(Int(value.wrappedValue))").monospacedDigit().frame(width: 24)
            }
        }
    }
}
