import SwiftUI

/// 云端识别服务的配置表单:API Key、区域、模型、接口地址,支持测试连接。
/// 模型从列表里选:OpenAI 兼容服务在填好地址和 Key 后自动从接口拉取,其他服务列出官方文档里的实时识别模型。
/// 保存后立即生效(下一次听写 / 字幕就会使用新配置)。
struct CloudConfigSheet: View {
    let provider: CloudProvider
    let store: CloudASRStore
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var config = CloudConfig(apiKey: "", model: "", region: .mainland, baseURL: "")
    @State private var testState: TestState = .idle
    @State private var models: [ModelOption] = []
    @State private var loadingModels = false
    @State private var modelsError: String?
    @State private var refreshToken = 0

    private enum TestState: Equatable {
        case idle, testing, ok, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: provider.displayName).font(.system(size: 16, weight: .semibold))
                Text(verbatim: provider.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card {
                VStack(spacing: DS.Space.m) {
                    row("API Key") {
                        SecureField("", text: $config.apiKey, prompt: Text("粘贴 API Key"))
                    }
                    if !provider.regions.isEmpty {
                        Divider()
                        row("区域") {
                            Picker("", selection: $config.region) {
                                ForEach(provider.regions) { Text(verbatim: $0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                        }
                    }
                    if provider.needsBaseURL {
                        Divider()
                        row("接口地址") { TextField("", text: $config.baseURL, prompt: Text(verbatim: "https://api.openai.com/v1")) }
                    }
                    Divider()
                    row("模型") {
                        ModelPickerField(selection: $config.model, options: models,
                                         loading: loadingModels, error: modelsError,
                                         onRefresh: provider.canFetchModels ? { refreshToken += 1 } : nil,
                                         placeholder: provider.defaultModel)
                    }
                }
            }
            .textFieldStyle(.plain)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Hint("API Key 只保存在本机。使用云端识别时，录音会发送到该服务商的服务器。")
            }
            Link(destination: provider.consoleURL) {
                Label("获取 API Key", systemImage: "arrow.up.right.square").font(.system(size: 12))
            }

            HStack(spacing: DS.Space.s) {
                Button { test() } label: {
                    if testState == .testing { ProgressView().controlSize(.small) } else { Text("测试连接") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!config.isComplete(for: provider) || testState == .testing)
                switch testState {
                case .ok:
                    Label("连接正常", systemImage: "checkmark.circle.fill").foregroundStyle(DS.success).font(.system(size: 12))
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(DS.danger).font(.system(size: 12))
                        .lineLimit(3)
                default:
                    EmptyView()
                }
                Spacer()
                if store.isConfigured(provider) {
                    Button("移除配置", role: .destructive) {
                        store.remove(provider)
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("删除本机保存的 API Key")
                }
                Button("取消") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.update(provider, config)
                    onSaved()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!config.isComplete(for: provider))
            }
        }
        .padding(DS.Space.l)
        .frame(width: 520)
        .onAppear {
            config = store.config(provider)
            models = provider.knownModels
        }
        .task(id: provider.canFetchModels ? "\(provider.needsBaseURL ? config.baseURL : "")|\(config.apiKey)|\(refreshToken)" : "") { await fetchModels() }
    }

    /// 能拉取模型列表的服务(OpenAI 兼容、Soniox):地址(需要时)和 Key 填好、输入停顿后拉取;失败时保留常用选项并显示原因。
    private func fetchModels() async {
        guard provider.canFetchModels else { return }
        modelsError = nil
        guard !provider.needsBaseURL || OpenAICompatibleAPI.endpoint(config.baseURL, "models") != nil,
              !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let fetched = try await CloudASREngine.fetchModels(provider: provider, config: config)
            guard !Task.isCancelled else { return }
            models = fetched.isEmpty ? provider.knownModels : fetched
        } catch {
            guard !Task.isCancelled else { return }
            models = provider.knownModels
            modelsError = String(localized: "无法获取模型列表：\(error.localizedDescription)", bundle: .l10n)
        }
    }

    private func row(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            content().font(.system(size: 12.5))
        }
    }

    private func test() {
        testState = .testing
        let provider = provider, config = config
        Task {
            if let error = await CloudASREngine.test(provider: provider, config: config) {
                testState = .failed(error)
            } else {
                testState = .ok
            }
        }
    }
}
