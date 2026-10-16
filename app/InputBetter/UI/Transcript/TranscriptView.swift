import AppKit
import SwiftUI

/// 字幕记录窗口:两个标签页——「字幕」显示本次(或刚结束的那次)字幕会话的全部内容,可以拷贝或保存成文件;
/// 「总结」由 AI 每隔一段时间总结一次(SummaryView)。
/// 只读 SubtitleController 的状态;保存 / 拷贝通过闭包交给外部(WindowManager)。
struct TranscriptView: View {
    let controller: SubtitleController
    let summarizer: TranscriptSummarizer
    let settings: AppSettings
    /// 打开 设置 › AI 润色与翻译。
    let onOpenSettings: () -> Void
    /// 固定在屏幕右侧(置顶、半透明)。
    let pin: TranscriptPinController
    /// 保存成文件(由 WindowManager 在本窗口上弹出保存面板)。
    let onSave: () -> Void

    /// 新内容到达时自动滚到最新(用户想往回看时可以关掉)。
    @State private var followLatest = true
    @State private var copied = false
    @State private var tab: Tab = Self.initialTab

    /// 调试用:IB_TRANSCRIPT_TAB=summary 直接打开「总结」页。
    private static var initialTab: Tab {
        #if DEBUG
        if ProcessInfo.processInfo.environment["IB_TRANSCRIPT_TAB"] == "summary" { return .summary }
        #endif
        return .captions
    }

    enum Tab: Hashable { case captions, summary }

    private var transcript: CaptionTranscript { controller.transcript }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .captions:
                if transcript.isEmpty && controller.partial.isEmpty {
                    empty
                } else {
                    list
                }
                Divider()
                footer
            case .summary:
                SummaryView(summarizer: summarizer, settings: settings, onOpenSettings: onOpenSettings)
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .background { background.ignoresSafeArea() }
    }

    /// 固定时和字幕条一样的深色半透明玻璃;平时是普通窗口背景。
    @ViewBuilder
    private var background: some View {
        if pin.isPinned {
            Rectangle().fill(.clear)
                .glassEffect(.regular.tint(.black.opacity(0.55)), in: .rect(cornerRadius: 16))
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Circle()
                .fill(controller.isRunning ? Color.red : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.appName.isEmpty ? String(localized: "字幕记录", bundle: .l10n) : transcript.appName)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                Text("字幕").tag(Tab.captions)
                Text("总结").tag(Tab.summary)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button { pin.toggle() } label: {
                Image(systemName: pin.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(pin.isPinned ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(pin.isPinned ? "取消固定" : "固定在屏幕右侧（始终在最前面，半透明）")
            .accessibilityLabel(pin.isPinned ? "取消固定" : "固定在屏幕右侧")
            if tab == .captions {
                Toggle("跟随最新", isOn: $followLatest)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.xs)  // 内容已从透明标题栏下方开始,只留一点间距
        .padding(.bottom, DS.Space.m)
    }

    private var statusText: String {
        let count = transcript.entries.count
        if controller.isRunning {
            return String(localized: "正在转录 · \(count) 句", bundle: .l10n)
        }
        if transcript.isEmpty { return String(localized: "还没有字幕", bundle: .l10n) }
        return String(localized: "已结束 · \(count) 句", bundle: .l10n)
    }

    // MARK: - 列表

    /// 正文用 NSTextView 显示(见 TranscriptTextView:可跨行选择,避免 LazyVStack 的颠倒渲染问题)。
    private var list: some View {
        TranscriptTextView(transcript: transcript,
                           partial: controller.isRunning ? controller.partial : "",
                           followLatest: followLatest)
    }

    private var empty: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("开始实时字幕后，这里会显示完整的转录内容。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Hint("记录只保存在内存中，下次开始字幕或退出 app 后清除。")
            Spacer()
            Button(copied ? LocalizedStringKey("已拷贝") : LocalizedStringKey("拷贝全部")) { copyAll() }
                .buttonStyle(SecondaryButtonStyle())
            Button("保存…", action: onSave)
                .buttonStyle(PrimaryButtonStyle())
        }
        .disabled(transcript.isEmpty)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.plainText(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
