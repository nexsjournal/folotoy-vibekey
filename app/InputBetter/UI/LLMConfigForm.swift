import SwiftUI

/// LLM 配置表单:服务商预设 + 接口地址 + Key + 模型 + 连接测试。设置 › AI 服务和引导共用。
/// 直接编辑主 LLM 配置(`AppSettings` 的地址 / Key / 模型);模型列表来自注入的 `LLMModelCatalog`
/// (和各功能的模型菜单是同一份列表,地址或 Key 改动后由它自动重新拉取),表单本身不发 `/models` 请求。
struct LLMConfigForm: View {
    @Bindable var settings: AppSettings
    /// 主 LLM 接口的模型列表(AppState 注入,全 app 一份)。
    let catalog: LLMModelCatalog

    private struct Preset: Identifiable {
        let name: String
        let url: String
        let model: String
        var id: String { name }
    }

    private let presets = [
        Preset(name: "OpenAI", url: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        Preset(name: "DeepSeek", url: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        Preset(name: String(localized: "通义千问", bundle: .l10n), url: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
        Preset(name: "OpenRouter", url: "https://openrouter.ai/api/v1", model: ""),
        Preset(name: String(localized: "Ollama 本地", bundle: .l10n), url: "http://localhost:11434/v1", model: ""),
    ]

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, ok(String), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: 6) {
                ForEach(presets) { preset in
                    Button(preset.name) {
                        settings.llmBaseURL = preset.url
                        settings.llmModel = preset.model
                        testState = .idle
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .overlay(Capsule().strokeBorder(settings.llmBaseURL == preset.url ? DS.accent : .clear, lineWidth: 1.2))
                }
            }

            Card {
                VStack(spacing: DS.Space.m) {
                    field("接口地址") {
                        TextField("https://api.openai.com/v1", text: $settings.llmBaseURL)
                    }
                    Divider()
                    field("API Key") {
                        SecureField("sk-…（本地模型可留空）", text: $settings.llmAPIKey)
                    }
                    Divider()
                    field("模型") {
                        ModelPickerField(selection: $settings.llmModel, options: modelOptions,
                                         loading: catalog.loading, error: modelsError,
                                         onRefresh: { catalog.refresh() }, placeholder: "gpt-4o-mini")
                    }
                }
            }

            HStack(spacing: DS.Space.s) {
                Button {
                    test()
                } label: {
                    if testState == .testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("测试连接")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(settings.llmBaseURL.isEmpty || testState == .testing)
                switch testState {
                case .ok(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(DS.success).font(.system(size: 12))
                case .failed(let msg):
                    Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(DS.danger).font(.system(size: 12)).lineLimit(2)
                default:
                    EmptyView()
                }
            }
        }
        .textFieldStyle(.plain)
        .onAppear { catalog.loadIfNeeded() }
    }

    /// 当前接口地址的模型;列表还属于旧地址(改了地址、新列表还没回来)时不显示,避免选到别家的模型。
    private var modelOptions: [ModelOption] {
        catalog.loadedBase == settings.llmBaseURL ? ModelOption.ids(catalog.models) : []
    }

    /// 模型列表下方的说明:拉取失败的原因,或接口确实没有返回模型(此时可以手动输入)。
    private var modelsError: String? {
        if let error = catalog.error {
            return String(localized: "无法获取模型列表：\(error)", bundle: .l10n)
        }
        if !catalog.loading, catalog.loadedBase == settings.llmBaseURL, catalog.models.isEmpty {
            return String(localized: "接口没有返回可用模型，可以手动输入", bundle: .l10n)
        }
        return nil
    }

    private func field(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            content().font(.system(size: 12.5))
        }
    }

    /// 用一句话做真实请求,确认地址、Key 和模型都可用。
    private func test() {
        guard !settings.llmModel.isEmpty else {
            testState = .failed(String(localized: "请先选择模型", bundle: .l10n))
            return
        }
        testState = .testing
        Task {
            do {
                let started = Date()
                _ = try await LLMClient(config: .init(baseURL: settings.llmBaseURL, apiKey: settings.llmAPIKey, model: settings.llmModel))
                    .complete(system: "Reply with OK.", user: "ping")
                testState = .ok(String(localized: "连接正常 · \(Int(Date().timeIntervalSince(started) * 1000)) ms", bundle: .l10n))
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
