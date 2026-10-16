import AppKit
import SwiftUI

/// 字幕记录窗口的「总结」页:AI 每隔一段时间总结一次新内容。
/// 只有这一页显示着、并且打开了「自动总结」时才会总结(见 TranscriptSummarizer);切走或关窗口即暂停。
///
/// 布局(内容为主、控件退后):
/// - 顶部一行控制条:自动总结开关、间隔;右侧是接口 · 模型菜单(接口来自设置)和「设置」;
/// - 中间:空状态给出说明和操作;有总结后按时间线排列,每段一个时间点 + 要点列表;
/// - 底部:状态、立即总结、拷贝。
struct SummaryView: View {
    let summarizer: TranscriptSummarizer
    @Bindable var settings: AppSettings
    /// 打开 设置 › AI 润色与翻译(接口只能在设置里配置)。
    let onOpenSettings: () -> Void
    @State private var copied = false
    /// 设置里那个接口提供的模型(GET /models)。
    @State private var models: [String] = []

    private static let intervals = [1, 2, 5, 10]

    var body: some View {
        @Bindable var summarizer = summarizer
        VStack(spacing: 0) {
            controlBar(enabled: $summarizer.enabled)
            Divider()
            if summarizer.sections.isEmpty {
                emptyState
            } else {
                timeline
            }
            Divider()
            footer
        }
        .onAppear { summarizer.setTabVisible(true) }
        .onDisappear { summarizer.setTabVisible(false) }
        .task(id: "\(settings.llmBaseURL)|\(settings.llmAPIKey)") { await loadModels() }
    }

    // MARK: - 控制条

    private func controlBar(enabled: Binding<Bool>) -> some View {
        HStack(spacing: DS.Space.m) {
            Toggle(isOn: enabled) {
                Text("自动总结").font(.system(size: 12.5, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!summarizer.isConfigured)
            // 菜单项直接列出(带勾选):菜单里嵌内联 Picker 会多出一个空的分组标题行。
            Menu {
                ForEach(Self.intervals, id: \.self) { minutes in
                    Toggle("每 \(minutes) 分钟", isOn: choice($settings.summaryInterval, minutes))
                }
            } label: {
                Text("每 \(settings.summaryInterval) 分钟").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: DS.Space.m)
            if settings.llmConfigured {
                modelMenu
            } else {
                Text("未配置 AI 服务").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("设置", action: onOpenSettings)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 10)
    }

    /// 接口 · 模型:接口来自设置(只显示),模型从该接口的模型列表里选。
    private var modelMenu: some View {
        Menu {
            Section(String(localized: "接口：\(host(settings.llmBaseURL))", bundle: .l10n)) {
                Toggle("跟随 AI 设置（\(settings.llmModel)）", isOn: choice($settings.summaryModel, ""))
                if !settings.summaryModel.isEmpty, !models.contains(settings.summaryModel) {
                    Toggle(settings.summaryModel, isOn: choice($settings.summaryModel, settings.summaryModel))
                }
            }
            if !models.isEmpty {
                Section(String(localized: "可用模型", bundle: .l10n)) {
                    ForEach(models, id: \.self) { model in
                        Toggle(model, isOn: choice($settings.summaryModel, model))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: 10.5))
                Text(verbatim: "\(host(settings.llmBaseURL)) · \(settings.summaryModel.isEmpty ? settings.llmModel : settings.summaryModel)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260, alignment: .trailing)
        .help("总结使用 设置 › AI 润色与翻译 里配置的接口，模型可以另选")
    }

    // MARK: - 空状态

    /// 空状态只做说明,不放按钮:开关、设置在顶部控制条,立即总结在底部,避免同一功能出现两处。
    private var emptyState: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                Circle().fill(DS.accent.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: "sparkles").font(.system(size: 22, weight: .medium)).foregroundStyle(DS.accent)
            }
            Text("AI 总结").font(.system(size: 15, weight: .semibold))
            Text(summarizer.isConfigured
                 ? String(localized: "打开上方的「自动总结」，每隔 \(settings.summaryInterval) 分钟总结一次刚才的内容，要点按时间排列在这里。", bundle: .l10n)
                 : String(localized: "总结使用 设置 › AI 润色与翻译 里配置的服务，请先配置。", bundle: .l10n))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let error = summarizer.error {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(DS.danger)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 时间线

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 总结段数不多,用普通 VStack(可选择文字在 LazyVStack 里有渲染问题)。
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(summarizer.sections) { section in
                        sectionRow(section, isLast: section.id == summarizer.sections.last?.id)
                            .id(section.id)
                    }
                    if let error = summarizer.error {
                        Text(verbatim: error).font(.system(size: 12)).foregroundStyle(DS.danger).padding(.leading, 22)
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: summarizer.sections) {
                if let last = summarizer.sections.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// 一段总结:左侧时间线(圆点 + 连线),右侧时间范围和要点列表。
    private func sectionRow(_ section: TranscriptSummarizer.Section, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(spacing: 4) {
                Circle()
                    .fill(section.generating ? DS.accent : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                }
            }
            .frame(width: 10)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(verbatim: section.range)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if section.generating { ProgressView().controlSize(.mini) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(Self.points(section.text).enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if point.isBullet {
                                Text(verbatim: "•").foregroundStyle(.secondary)
                            }
                            Text(verbatim: point.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .textSelection(.enabled)
            }
            .padding(.bottom, isLast ? 0 : DS.Space.l)
        }
    }

    /// 把 AI 输出的要点("- xxx" 每行一条)拆成列表项;不是要点格式的行按普通段落显示。
    static func points(_ text: String) -> [(text: String, isBullet: Bool)] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { return [("…", false)] }
        return lines.map { line in
            for marker in ["- ", "• ", "* ", "· "] where line.hasPrefix(marker) {
                return (String(line.dropFirst(marker.count)), true)
            }
            return (line, false)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: DS.Space.m) {
            if summarizer.isGenerating { ProgressView().controlSize(.mini) }
            Text(statusText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if let next = summarizer.nextSummaryAt {
                // 每秒刷新一次倒计时。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(countdown(to: next, now: context.date))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button { summarizer.summarizeNow() } label: {
                Label("立即总结", systemImage: "sparkles")
            }
            .buttonStyle(.borderless)
            .disabled(!summarizer.isConfigured || summarizer.isGenerating || summarizer.pendingCount == 0)
            Button { copy() } label: {
                Label(copied ? LocalizedStringKey("已拷贝") : LocalizedStringKey("拷贝"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(summarizer.plainText.isEmpty)
        }
        .font(.system(size: 12))
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 10)
    }

    /// "下次总结 1:23";到点后新内容不够时说明在等内容。
    private func countdown(to next: Date, now: Date) -> String {
        let remaining = Int(next.timeIntervalSince(now).rounded(.up))
        if remaining <= 0 {
            return summarizer.pendingCount < TranscriptSummarizer.minimumSentences
                ? String(localized: "· 等待更多内容", bundle: .l10n)
                : String(localized: "· 即将总结", bundle: .l10n)
        }
        return String(localized: "· 下次总结 \(remaining / 60):\(String(format: "%02d", remaining % 60))", bundle: .l10n)
    }

    private var statusText: String {
        if !summarizer.isConfigured { return String(localized: "未配置模型", bundle: .l10n) }
        if summarizer.isGenerating { return String(localized: "正在总结…", bundle: .l10n) }
        if !summarizer.enabled { return String(localized: "自动总结已关闭", bundle: .l10n) }
        return String(localized: "待总结 \(summarizer.pendingCount) 句", bundle: .l10n)
    }

    // MARK: - 内部

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summarizer.plainText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// 菜单里单选项的勾选状态:当前值等于 `value` 时打勾,点它就选它。
    private func choice<T: Equatable>(_ selection: Binding<T>, _ value: T) -> Binding<Bool> {
        Binding(get: { selection.wrappedValue == value }, set: { if $0 { selection.wrappedValue = value } })
    }

    /// 拉取设置里那个接口的模型列表(失败时只保留"跟随 AI 设置")。
    private func loadModels() async {
        guard settings.llmConfigured else { return }
        models = (try? await OpenAICompatibleAPI.listModels(baseURL: settings.llmBaseURL, apiKey: settings.llmAPIKey)) ?? []
    }

    private func host(_ baseURL: String) -> String {
        URL(string: baseURL)?.host ?? baseURL
    }
}
