import SwiftUI

/// 在线翻译服务的配置表单(结构同 CloudConfigSheet):按服务列出要填的密钥 / 区域,
/// 「测试连接」会真的翻译一句并显示译文(同时验证了密钥、签名和语言代码)。
/// 底部「使用此服务」可以直接勾选用于实时字幕 / 听写(从哪个场景进来就默认勾上哪个),配置完就能用,不用再去别处选。
/// 保存后立即生效。
struct TranslationProviderSheet: View {
    /// 用于哪些场景。
    struct Usage: Equatable {
        var subtitles: Bool
        var dictation: Bool
    }

    let provider: TranslationProvider
    let store: MachineTranslationStore
    var initialUsage = Usage(subtitles: false, dictation: false)
    /// 保存后调用,带上「使用此服务」的勾选。
    var onSaved: (Usage) -> Void = { _ in }
    var onRemoved: () -> Void = {}
    @State private var usage = Usage(subtitles: false, dictation: false)

    @Environment(\.dismiss) private var dismiss
    @State private var credentials = MTCredentials()
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, ok(String), failed(String)
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
                    ForEach(Array(provider.fields.enumerated()), id: \.element) { index, field in
                        if index > 0 { Divider() }
                        row(provider.label(for: field)) { input(for: field) }
                    }
                }
            }
            .textFieldStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "gift").foregroundStyle(.secondary)
                    Hint(verbatim: provider.freeTier + String(localized: "（以服务商官网为准）", bundle: .l10n))
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Hint("密钥只保存在本机。使用在线翻译时，字幕和听写的文字会发送到该服务商。")
                }
                Link(destination: provider.consoleURL) {
                    Label("获取密钥", systemImage: "arrow.up.right.square").font(.system(size: 12))
                }
            }

            HStack(spacing: DS.Space.l) {
                Text("使用此服务").font(.system(size: 12.5)).foregroundStyle(.secondary)
                Toggle("实时字幕", isOn: $usage.subtitles).toggleStyle(.checkbox)
                Toggle("听写翻译", isOn: $usage.dictation).toggleStyle(.checkbox)
            }
            .font(.system(size: 12.5))

            HStack(spacing: DS.Space.s) {
                Button { test() } label: {
                    if testState == .testing { ProgressView().controlSize(.small) } else { Text("测试连接") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!credentials.isComplete(for: provider) || testState == .testing)
                testResult
                Spacer()
                if store.isConfigured(provider) {
                    Button("移除配置", role: .destructive) {
                        store.remove(provider)
                        onRemoved()
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("删除本机保存的密钥")
                }
                Button("取消") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.update(provider, credentials)
                    onSaved(usage)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!credentials.isComplete(for: provider))
            }
        }
        .padding(DS.Space.l)
        .frame(width: 540)
        .onAppear {
            credentials = store.credentials(provider)
            usage = initialUsage
        }
        .onChange(of: credentials) { testState = .idle }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testState {
        case .ok(let sample):
            Label(String(localized: "连接正常：\(sample)", bundle: .l10n), systemImage: "checkmark.circle.fill")
                .foregroundStyle(DS.success).font(.system(size: 12)).lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(DS.danger).font(.system(size: 12))
                .lineLimit(3)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func input(for field: CredentialField) -> some View {
        let binding = Binding(get: { credentials[field] }, set: { credentials[field] = $0 })
        if field == .region, !provider.regions.isEmpty {
            Picker("", selection: binding) {
                ForEach(provider.regions, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
        } else if field == .region {
            TextField("", text: binding, prompt: Text("如 eastasia；全局资源留空"))
        } else if provider.isSecret(field) {
            SecureField("", text: binding, prompt: Text("粘贴 \(provider.label(for: field))"))
        } else {
            TextField("", text: binding, prompt: Text("粘贴 \(provider.label(for: field))"))
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(verbatim: title).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            content().font(.system(size: 12.5))
        }
    }

    private func test() {
        testState = .testing
        let provider = provider, credentials = credentials
        Task {
            do {
                testState = .ok(try await MachineTranslatorFactory.test(provider, credentials: credentials))
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
