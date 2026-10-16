import AppKit
import SwiftUI

/// 字幕记录窗口的「总结」页:AI 每隔一段时间总结一次新内容。
/// 只有这一页显示着、并且打开了「自动总结」时才会总结(见 TranscriptSummarizer);切走或关窗口即暂停。
struct SummaryView: View {
    let summarizer: TranscriptSummarizer
    @Bindable var settings: AppSettings
    /// 打开 设置 › AI 润色与翻译(接口只能在设置里配置)。
    let onOpenSettings: () -> Void
    @State private var copied = false
    /// 设置里那个接口提供的模型(GET /models)。
    @State private var models: [String] = []
    @State private var loadingModels = false

    private static let intervals = [1, 2, 5, 10]

    var body: some View {
        @Bindable var summarizer = summarizer
        VStack(spacing: 0) {
            toolbar(enabled: $summarizer.enabled)
            Divider()
            content
            Divider()
            footer
        }
        .onAppear { summarizer.setTabVisible(true) }
        .onDisappear { summarizer.setTabVisible(false) }
    }

    // MARK: - 工具条

    /// 紧凑的两行工具条(总结页的主体是阅读内容,控件要轻、次要):
    /// 第一行:自动总结开关、间隔、立即总结;第二行:小字显示接口(来自设置,只能去设置里改)和模型下拉菜单。
    private func toolbar(enabled: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: DS.Space.m) {
                Toggle(isOn: enabled) {
                    Text("自动总结").font(.system(size: 12.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!summarizer.isConfigured)
                Menu {
                    Picker("", selection: $settings.summaryInterval) {
                        ForEach(Self.intervals, id: \.self) { Text("每 \($0) 分钟").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("每 \(settings.summaryInterval) 分钟").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    summarizer.summarizeNow()
                } label: {
                    Label("立即总结", systemImage: "sparkles").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(!summarizer.isConfigured || summarizer.isGenerating || summarizer.pendingCount == 0)
            }
            HStack(spacing: 6) {
                if settings.llmConfigured {
                    Text("接口").foregroundStyle(.tertiary)
                    Text(verbatim: host(settings.llmBaseURL))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text("模型").foregroundStyle(.tertiary)
                    Menu {
                        Picker("", selection: $settings.summaryModel) {
                            Text("跟随 AI 设置（\(settings.llmModel)）").tag("")
                            if !settings.summaryModel.isEmpty, !models.contains(settings.summaryModel) {
                                Text(verbatim: settings.summaryModel).tag(settings.summaryModel)
                            }
                            if !models.isEmpty { Divider() }
                            ForEach(models, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(verbatim: settings.summaryModel.isEmpty ? settings.llmModel : settings.summaryModel)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    if loadingModels { ProgressView().controlSize(.mini) }
                    Spacer(minLength: DS.Space.s)
                    Button("修改接口…", action: onOpenSettings).buttonStyle(.borderless)
                } else {
                    Text("总结使用 设置 › AI 润色与翻译 里配置的服务").foregroundStyle(.secondary)
                    Spacer(minLength: DS.Space.s)
                    Button("去配置…", action: onOpenSettings).buttonStyle(.borderless)
                }
            }
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(.primary.opacity(0.03))
        .task(id: "\(settings.llmBaseURL)|\(settings.llmAPIKey)") { await loadModels() }
    }

    private var statusText: String {
        if !summarizer.isConfigured { return String(localized: "未配置模型", bundle: .l10n) }
        if summarizer.isGenerating { return String(localized: "正在总结…", bundle: .l10n) }
        if !summarizer.enabled { return String(localized: "自动总结已关闭", bundle: .l10n) }
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
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(summarizer.sections) { section in
                            sectionView(section).id(section.id)
                        }
                        if let error = summarizer.error {
                            Text(verbatim: error).font(.system(size: 12)).foregroundStyle(DS.danger)
                        }
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.m)
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

    /// 一段总结:时间范围 + 要点,放在浅色卡片里,段与段之间分隔清楚。
    private func sectionView(_ section: TranscriptSummarizer.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10))
                Text(verbatim: section.range).font(.system(size: 11, design: .monospaced))
                if section.generating { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(.secondary)
            Text(verbatim: section.text.isEmpty ? "…" : section.text)
                .font(.system(size: 13.5))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            if summarizer.isGenerating { ProgressView().controlSize(.small) }
            Text(statusText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
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

    /// 拉取设置里那个接口的模型列表(失败时只保留"跟随 AI 设置")。
    private func loadModels() async {
        loadingModels = true
        defer { loadingModels = false }
        models = (try? await OpenAICompatibleAPI.listModels(baseURL: settings.llmBaseURL, apiKey: settings.llmAPIKey)) ?? []
    }

    private func host(_ baseURL: String) -> String {
        URL(string: baseURL)?.host ?? baseURL
    }
}
