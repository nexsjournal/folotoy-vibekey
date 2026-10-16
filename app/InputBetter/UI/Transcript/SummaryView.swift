import AppKit
import SwiftUI

/// 字幕记录窗口的「总结」页:AI 每隔一段时间总结一次新内容。
/// 只有这一页显示着、并且打开了「自动总结」时才会总结(见 TranscriptSummarizer);切走或关窗口即暂停。
struct SummaryView: View {
    let summarizer: TranscriptSummarizer
    @Bindable var settings: AppSettings
    @State private var showsModel = false
    @State private var copied = false

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
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Picker("", selection: $settings.summaryUsesCustomLLM) {
                        Text("使用 AI 设置里的服务").tag(false)
                        Text("单独指定").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if settings.summaryUsesCustomLLM {
                        LLMConfigForm(baseURL: $settings.summaryBaseURL, apiKey: $settings.summaryAPIKey,
                                      model: $settings.summaryModel, showsPresets: false)
                    } else if !settings.llmConfigured {
                        Hint("AI 设置里还没有配置服务，请先在 设置 › AI 润色与翻译 中配置，或选择「单独指定」。")
                    }
                }
                .padding(.top, DS.Space.s)
            } label: {
                Text(verbatim: modelLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    /// 折叠时显示当前用的模型。
    private var modelLabel: String {
        guard let config = settings.summaryLLMConfig else { return String(localized: "模型：未配置", bundle: .l10n) }
        let host = URL(string: config.baseURL)?.host ?? config.baseURL
        return String(localized: "模型：\(config.model) · \(host)", bundle: .l10n)
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
