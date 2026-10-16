import SwiftUI

/// 识别模型:下载 / 切换听写模型,单独指定字幕模型,镜像下载。
struct ModelsPane: View {
    let app: AppState

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "听写模型", footer: "右键已下载的模型可以删除。首次加载 Whisper 时系统需要为本机优化模型，可能需要一两分钟。") {
                ModelList(models: app.models, cloud: app.cloudASR, selection: $settings.dictationModelID, allowsDelete: true,
                          items: ModelCatalog.all.filter { $0.cloudProvider == nil })
            }
            SettingsSection(title: "云端识别", footer: "填入你自己的 API Key 后即可用于听写和字幕，按服务商价格计费。使用时录音会发送到服务商的服务器。") {
                ModelList(models: app.models, cloud: app.cloudASR, selection: $settings.dictationModelID,
                          items: ModelCatalog.all.filter { $0.cloudProvider != nil })
            }
            SettingsSection(title: "字幕", footer: "Apple Speech 与云端流式服务的字幕延迟最低；其他本地模型按句识别，准确率更高。") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        SettingRow(title: "字幕使用的模型") {
                            Picker("", selection: $settings.subtitleModelID) {
                                Text("与听写相同").tag("")
                                ForEach(ModelCatalog.all.filter { app.models.isInstalled($0.id) }) { Text($0.name).tag($0.id) }
                                // 选中的模型已删除 / 云端配置已移除:仍显示出来并标明不可用,不让选择框变空白。
                                if !settings.subtitleModelID.isEmpty, !app.models.isInstalled(settings.subtitleModelID) {
                                    Text("\(ModelCatalog.model(settings.subtitleModelID)?.name ?? settings.subtitleModelID)（不可用）")
                                        .tag(settings.subtitleModelID)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider()
                        SettingRow(title: "使用国内镜像下载", detail: "通过 hf-mirror.com 下载 Whisper 与 SenseVoice") {
                            Toggle("", isOn: $settings.useMirror).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
            }
            if let loading = app.engines.loadingModelID, let model = ModelCatalog.model(loading) {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Hint("正在加载 \(model.name)…")
                }
                .padding(.top, DS.Space.m)
            }
        }
    }
}
