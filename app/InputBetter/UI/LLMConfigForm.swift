import SwiftUI

/// LLM 配置表单:服务商预设 + 地址 + Key + 模型 + 连接测试。
/// 地址或 Key 改动后自动从接口拉取模型列表(GET /models,输入停顿 0.6 秒后请求),在下拉菜单里选择。
struct LLMConfigForm: View {
    @Bindable var settings: AppSettings

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

    @State private var availableModels: [ModelOption] = []
    @State private var loadingModels = false
    @State private var modelsError: String?
    /// 手动点"重新获取"时递增,触发重新拉取。
    @State private var refreshToken = 0
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
                    field("API 地址") {
                        TextField("https://api.openai.com/v1", text: $settings.llmBaseURL)
                    }
                    Divider()
                    field("API Key") {
                        SecureField("sk-…（本地模型可留空）", text: $settings.llmAPIKey)
                    }
                    Divider()
                    field("模型") {
                        ModelPickerField(selection: $settings.llmModel, options: availableModels,
                                         loading: loadingModels, error: modelsError,
                                         onRefresh: { refreshToken += 1 }, placeholder: "gpt-4o-mini")
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
        .task(id: "\(settings.llmBaseURL)|\(settings.llmAPIKey)|\(refreshToken)") { await fetchModels() }
    }

    /// 拉取模型列表。地址无效时不请求;连续输入时等停顿后再请求(task 被新的 id 取消即放弃)。
    private func fetchModels() async {
        modelsError = nil
        guard OpenAICompatibleAPI.endpoint(settings.llmBaseURL, "models") != nil else {
            availableModels = []
            return
        }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let ids = try await OpenAICompatibleAPI.listModels(baseURL: settings.llmBaseURL, apiKey: settings.llmAPIKey)
            guard !Task.isCancelled else { return }
            availableModels = ModelOption.ids(ids)
            if ids.isEmpty { modelsError = String(localized: "接口没有返回可用模型，可以手动输入", bundle: .l10n) }
        } catch {
            guard !Task.isCancelled else { return }
            availableModels = []
            modelsError = String(localized: "无法获取模型列表：\(error.localizedDescription)", bundle: .l10n)
        }
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
