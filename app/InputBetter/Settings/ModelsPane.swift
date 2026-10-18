import SwiftUI

/// 识别模型:下载 / 切换听写模型、配置云端识别、镜像下载。
/// 字幕用哪个模型属于字幕的设置,在「实时字幕」页(SubtitlesPane)选,这里不重复放。
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
            SettingsSection(title: "下载") {
                Card {
                    SettingRow(title: "使用国内镜像下载", detail: "通过 hf-mirror.com 下载 Whisper 与 SenseVoice") {
                        Toggle("", isOn: $settings.useMirror).labelsHidden().toggleStyle(.switch)
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
