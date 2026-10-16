import AppKit
import SwiftUI

/// 字幕条:胶囊展开后的形态,采用同传类应用的两行滚动字幕:
/// - 原文行跟着语音实时走,译文行按句接上(通常比原文慢一两句),见 CaptionFeed / RollingCaptions;
/// - 平时只有字幕文字;鼠标悬停时上方出现标题栏(直播标记、应用名、翻译菜单、工具按钮)。
/// 背景玻璃由 PillView 统一加,以便和胶囊之间做变形动画。
struct SubtitleSurface: View {
    let controller: SubtitleController
    /// 翻译是否可用(系统翻译语言包已下载,或配置了 AI)。
    let translation: TranslationService
    @Bindable var settings: AppSettings
    let permissions: Permissions
    let hovering: Bool
    /// 字幕运行时也可以听写(听写优先,字幕暂停解码,结束后补上)。
    let onDictate: () -> Void
    /// 打开字幕记录窗口(查看前面的全部字幕)。
    let onTranscript: () -> Void
    /// 打开翻译设置(翻译不可用时引导去下载系统翻译语言或配置 AI)。
    let onTranslationSettings: () -> Void
    let onCollapse: () -> Void
    let onStop: () -> Void

    private var fontSize: CGFloat { settings.subtitleFontSize }

    /// 标题栏是否显示,和"宽度是否按标题栏留出"分开控制,做成两步动画:
    /// 移开时先淡出标题栏、再收窄;移入时先加宽、再淡入标题栏——按钮不会跟着宽度变化漂移。
    @State private var headerShown = false
    @State private var headerWidth = false
    @State private var headerTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                header.transition(.opacity)
            }
            content
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, showsHeader ? 10 : 9)
        .padding(.bottom, 11)
        .frame(width: surfaceWidth, alignment: .leading)
        .animation(.spring(duration: 0.25, bounce: 0), value: surfaceWidth)
        .onChange(of: wantsHeader, initial: true) { _, show in updateHeader(show) }
    }

    /// 两步切换标题栏(见 headerShown)。
    private func updateHeader(_ show: Bool) {
        headerTask?.cancel()
        if show {
            headerWidth = true
            headerTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) { headerShown = true }
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) { headerShown = false }
            headerTask = Task {
                try? await Task.sleep(for: .milliseconds(130))
                guard !Task.isCancelled else { return }
                headerWidth = false
            }
        }
    }

    private static let horizontalPadding: CGFloat = 20

    /// 标题栏(应用名、翻译菜单、工具)只在悬停时显示;启动失败时一直显示(需要关闭按钮)。
    private var wantsHeader: Bool {
        if case .failed = controller.status { return true }
        return hovering
    }

    private var showsHeader: Bool { headerShown }

    /// 最宽:随字号变化,最多 940。
    private var maxWidth: CGFloat { min(max(fontSize * 30, 540), 940) }

    /// 字幕条宽度:有字幕后固定为最大宽度——滚动字幕的换行位置依赖宽度,宽度一变整段就会重排跳动;
    /// 还没有字幕时用紧凑宽度。悬停时至少放得下标题栏。
    private var surfaceWidth: CGFloat {
        let hasText = controller.feed.captions.hasSource
        let content: CGFloat = controller.status == .running && hasText && !controller.silentTooLong ? maxWidth : 420
        return min(max(content, headerWidth ? 500 : 200), maxWidth)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            LiveDot(level: controller.level, active: controller.status == .running)
            Text(controller.appName.isEmpty ? String(localized: "字幕", bundle: .l10n) : controller.appName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            translationMenu
            Spacer(minLength: 12)
            if case .failed = controller.status {
                // 启动失败:没有可结束的字幕,只提供关闭(其他工具都没有意义)。
                tool("xmark", help: String(localized: "关闭", bundle: .l10n), action: onStop)
            } else {
                HStack(spacing: 2) {
                    tool("textformat.size.smaller", help: String(localized: "缩小字号", bundle: .l10n)) { settings.subtitleFontSize = max(14, fontSize - 2) }
                    tool("textformat.size.larger", help: String(localized: "放大字号", bundle: .l10n)) { settings.subtitleFontSize = min(44, fontSize + 2) }
                    tool("lock", help: String(localized: "锁定（鼠标穿透，可在菜单里解锁）", bundle: .l10n)) { settings.subtitleLocked = true }
                    tool("text.page", help: String(localized: "字幕记录", bundle: .l10n), action: onTranscript)
                    Divider().frame(height: 14).padding(.horizontal, 4)
                    tool("mic.fill", help: String(localized: "听写", bundle: .l10n), action: onDictate)
                    tool("chevron.down", help: String(localized: "收起成小胶囊", bundle: .l10n), action: onCollapse)
                    tool("stop.fill", help: String(localized: "结束字幕", bundle: .l10n), action: onStop)
                }

            }
        }
        .frame(height: 20)
    }

    /// 翻译菜单(标签样式):开关译文、直接选择目标语言,不用去设置里改。
    /// 关闭翻译时显示暗色的「译」,打开时显示「译 · 目标语言」。
    private var translationMenu: some View {
        Menu {
            if translation.isAvailable {
                Toggle("显示译文", isOn: $settings.subtitleTranslate)
                Divider()
                Picker("翻译成", selection: $settings.subtitleTarget) {
                    ForEach(TargetLanguage.allCases) { language in
                        Text(language == .auto ? "\(language.title)（\(TargetLanguage.autoSummary)）" : language.title).tag(language)
                    }
                }
                .pickerStyle(.inline)
            } else {
                Text("翻译需要下载系统翻译语言或配置 AI")
                Button("打开翻译设置…", action: onTranslationSettings)
            }
            if translation.isAvailable {
                Divider()
                Button("翻译设置…", action: onTranslationSettings)
            }
        } label: {
            Text(settings.subtitleTranslate ? "译 · \(settings.subtitleTarget.title)" : "译")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(settings.subtitleTranslate ? 0.75 : 0.4))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().strokeBorder(.white.opacity(settings.subtitleTranslate ? 0.3 : 0.15)))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(translation.isAvailable ? String(localized: "翻译设置", bundle: .l10n) : String(localized: "翻译需要下载系统翻译语言或配置 AI", bundle: .l10n))
    }

    // MARK: - 正文

    @ViewBuilder
    private var content: some View {
        switch controller.status {
        case .starting:
            hint("正在连接 \(controller.appName) 的声音…")
        case .failed(let message):
            // 原因已经是本地化后的文字,按原样显示。
            Text(verbatim: message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        default:
            if controller.silentTooLong {
                VStack(alignment: .leading, spacing: 6) {
                    hint("没有收到声音。请确认 \(controller.appName) 正在播放，并允许 InputBetter 录制系统音频。")
                    Button("打开隐私设置") { permissions.openSystemAudioSettings() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = controller.streamError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.danger)
                            .lineLimit(2)
                    }
                    transcript
                }
            }
        }
    }

    /// 字幕正文:两行滚动字幕(见 RollingCaptions)。翻译时原文(小、略暗)在上,跟着语音实时走;
    /// 译文(大、亮)在下,按句接上。各一个最多 2 行高的框,底部对齐,写满后最旧的一行整行滚出。
    /// 左对齐:滚动字幕居中时每次增长整行都会左右移动,左对齐才稳定。
    /// 文字不接收鼠标事件(超出框被裁掉的文字也不会挡住标题栏按钮)。
    private var transcript: some View {
        let captions = controller.feed.captions
        let translating = controller.feed.translating
        return VStack(alignment: .leading, spacing: translating ? 4 : 0) {
            if !captions.hasSource {
                Text("等待声音…")
                    .font(.system(size: smallSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            } else if translating {
                rollingBox(Text(captions.sourceFinal).foregroundStyle(.white.opacity(0.6))
                           + Text(captions.sourceLive).foregroundStyle(.white.opacity(0.4)),
                           size: smallSize, weight: .medium)
                if captions.translation.isEmpty {
                    Text("翻译中…")
                        .font(.system(size: smallSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                } else {
                    rollingBox(Text(captions.translation).foregroundStyle(.white), size: translationSize, weight: .semibold)
                }
            } else {
                rollingBox(Text(captions.sourceFinal).foregroundStyle(.white)
                           + Text(captions.sourceLive).foregroundStyle(.white.opacity(0.75)),
                           size: fontSize, weight: .semibold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .allowsHitTesting(false)
    }

    /// 原文字号(小)和译文字号:译文不用全字号,两行能放下更多内容,读者更容易跟上。
    private var smallSize: CGFloat { fontSize * 0.64 }
    private var translationSize: CGFloat { fontSize * 0.68 }

    /// 最多 2 行高的滚动框:文字按宽度自然换行,不足 2 行时按实际行数(刚开始不留空白),
    /// 超过 2 行时底部对齐、裁掉顶部多出的行。
    private func rollingBox(_ text: Text, size: CGFloat, weight: Font.Weight) -> some View {
        text
            .font(.system(size: size, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: Self.lineHeight(size: size, weight: weight) * 2, alignment: .bottom)
            // 不给高度提议,框就按文字的实际高度(最多 2 行),而不是撑满最大高度留出空白。
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
    }

    private static func nsFont(size: CGFloat, weight: Font.Weight) -> NSFont {
        let nsWeight: NSFont.Weight = switch weight {
        case .semibold: .semibold
        case .medium: .medium
        case .bold: .bold
        default: .regular
        }
        return NSFont.systemFont(ofSize: size, weight: nsWeight)
    }

    /// 系统字体在该字号下的行高(与 SwiftUI Text 的默认行距一致),用来固定正文高度。
    private static func lineHeight(size: CGFloat, weight: Font.Weight) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: nsFont(size: size, weight: weight)))
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.75))
        .help(help)
    }
}

/// 呼吸的直播圆点,声音越大光晕越强。
private struct LiveDot: View {
    let level: Float
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.35))
                .frame(width: 8 + CGFloat(level) * 10, height: 8 + CGFloat(level) * 10)
                .blur(radius: 2)
            Circle()
                .fill(active ? Color.red : Color.gray)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 1 : 0.55)
        }
        .frame(width: 18, height: 18)
        .animation(.easeOut(duration: 0.12), value: level)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
        }
    }
}
