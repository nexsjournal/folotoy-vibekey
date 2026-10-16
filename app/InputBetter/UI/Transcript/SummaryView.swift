import AppKit
import SwiftUI

/// 字幕记录窗口的「总结」页:AI 每隔一段时间总结一次新内容。
/// 只有这一页显示着、并且打开了「自动总结」时才会总结(见 TranscriptSummarizer);切走或关窗口即暂停。
struct SummaryView: View {
    let summarizer: TranscriptSummarizer
    @Bindable var settings: AppSettings
    /// 打开 设置 › AI 润色与翻译(接口只能在设置里配置)。
    let onOpenSettings: () -> Void
    @State private var showsModel = false
    @State private var copied = false
    /// 设置里那个接口提供的模型(GET /models)。
    @State private var models: [String] = []
    @State private var loadingModels = false

    private static let intervals = [1, 2, 5, 10]

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
            Divider()
            footer
        }
        .onAppear { summarizer.setTabVisible(true) }
        .onDisappear { summarizer.setTabVisible(false) }
        .onChange(of: settings.summaryEnabled) { summarizer.update() }
    }

    // MARK: - 控制栏

    private var controls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Toggle("自动总结", isOn: $settings.summaryEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5, weight: .medium))
                Picker("", selection: $settings.summaryInterval) {
                    ForEach(Self.intervals, id: \.self) { Text("每 \($0) 分钟").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Spacer()
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("立即总结") { summarizer.summarizeNow() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!summarizer.isConfigured || summarizer.isGenerating || summarizer.pendingCount == 0)
            }
            DisclosureGroup(isExpanded: $showsModel) {
                modelSettings.padding(.top, DS.Space.s)
            } label: {
                Text(verbatim: modelLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    /// 接口:只能用设置里配置的服务(这里只显示,去设置里改);模型:从该接口的模型列表里选。
    @ViewBuilder
    private var modelSettings: some View {
        if settings.llmConfigured {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Text("接口").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                    Text(verbatim: host(settings.llmBaseURL)).font(.system(size: 12))
                    Spacer()
                    Button("在设置中修改…", action: onOpenSettings)
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
                HStack(spacing: DS.Space.s) {
                    Text("模型").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                    Picker("", selection: $settings.summaryModel) {
                        Text("跟随 AI 设置（\(settings.llmModel)）").tag("")
                        if !settings.summaryModel.isEmpty, !models.contains(settings.summaryModel) {
                            Text(verbatim: settings.summaryModel).tag(settings.summaryModel)
                        }
                        ForEach(models, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    if loadingModels { ProgressView().controlSize(.small) }
                }
            }
            .task(id: "\(settings.llmBaseURL)|\(settings.llmAPIKey)") { await loadModels() }
        } else {
            HStack(spacing: DS.Space.s) {
                Hint("总结使用 设置 › AI 润色与翻译 里配置的服务，请先在那里配置。")
                Spacer()
                Button("打开 AI 设置…", action: onOpenSettings).buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    /// 拉取设置里那个接口的模型列表(失败时只保留"跟随 AI 设置")。
    private func loadModels() async {
        loadingModels = true
        defer { loadingModels = false }
        models = (try? await OpenAICompatibleAPI.listModels(baseURL: settings.llmBaseURL, apiKey: settings.llmAPIKey)) ?? []
    }

    private func host(_ baseURL: String) -> String {
        URL(string: baseURL)?.host ?? baseURL
    }

    /// 折叠时显示当前用的模型。
    private var modelLabel: String {
        guard let config = settings.summaryLLMConfig else { return String(localized: "模型：未配置", bundle: .l10n) }
        return String(localized: "模型：\(config.model) · \(host(config.baseURL))", bundle: .l10n)
    }

    private var statusText: String {
        if !summarizer.isConfigured { return String(localized: "未配置模型", bundle: .l10n) }
        if summarizer.isGenerating { return String(localized: "正在总结…", bundle: .l10n) }
        if !settings.summaryEnabled { return String(localized: "已暂停", bundle: .l10n) }
        return String(localized: "待总结 \(summarizer.pendingCount) 句", bundle: .l10n)
    }

    // MARK: - 总结内容

    @ViewBuilder
    private var content: some View {
        if summarizer.sections.isEmpty {
            VStack(spacing: DS.Space.s) {
                Image(systemName: "text.badge.star")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("打开「自动总结」后，每隔 \(settings.summaryInterval) 分钟会用 AI 总结一次这段时间的内容。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let error = summarizer.error {
                    Text(verbatim: error).font(.system(size: 12)).foregroundStyle(DS.danger)
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // 总结段数不多,用普通 VStack(可选择文字在 LazyVStack 里有渲染问题)。
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        ForEach(summarizer.sections) { section in
                            sectionView(section).id(section.id)
                        }
                        if let error = summarizer.error {
                            Text(verbatim: error).font(.system(size: 12)).foregroundStyle(DS.danger)
                        }
                    }
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: summarizer.sections) {
                    if let last = summarizer.sections.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func sectionView(_ section: TranscriptSummarizer.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: section.range)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if section.generating { ProgressView().controlSize(.mini) }
            }
            Text(verbatim: section.text.isEmpty ? "…" : section.text)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Hint("只在显示本页并打开「自动总结」时总结，关闭窗口自动暂停。")
            Spacer()
            Button(copied ? LocalizedStringKey("已拷贝") : LocalizedStringKey("拷贝总结")) { copy() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(summarizer.plainText.isEmpty)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summarizer.plainText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
