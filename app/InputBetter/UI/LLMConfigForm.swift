import SwiftUI

/// LLM 配置表单:服务商预设 + 地址 + Key + 模型(可拉取列表)+ 连接测试。
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

    @State private var availableModels: [String] = []
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
                        if !preset.model.isEmpty { settings.llmModel = preset.model }
                        availableModels = []
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
                        HStack(spacing: 6) {
                            TextField("例如 gpt-4o-mini", text: $settings.llmModel)
                            if !availableModels.isEmpty {
                                Menu {
                                    ForEach(availableModels, id: \.self) { m in Button(m) { settings.llmModel = m } }
                                } label: { Image(systemName: "chevron.down") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }
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
    }

    private func field(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            content().font(.system(size: 12.5))
        }
    }

    /// 先拉模型列表,再用一句话做真实请求,确认 Key 和模型都可用。
    private func test() {
        testState = .testing
        let client = LLMClient(config: .init(baseURL: settings.llmBaseURL, apiKey: settings.llmAPIKey, model: settings.llmModel))
        Task {
            if let list = try? await client.listModels() { availableModels = list }
            if settings.llmModel.isEmpty, let first = availableModels.first { settings.llmModel = first }
            guard !settings.llmModel.isEmpty else {
                testState = .failed(String(localized: "请填写模型名称", bundle: .l10n))
                return
            }
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
