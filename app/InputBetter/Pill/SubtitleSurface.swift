import AppKit
import SwiftUI

/// 字幕条:胶囊展开后的形态,采用同传类应用的滚动字幕:
/// - 原文行跟着语音实时走;译文行按句接上,末尾是正在说的半句的暂定译文(略暗),见 CaptionFeed / RollingCaptions;
/// - 平时只有字幕文字;鼠标悬停时上方出现标题栏(直播标记、应用名、「译」开关 + 语言、翻译方式菜单、工具按钮)。
/// 背景玻璃由 PillView 统一加,以便和胶囊之间做变形动画。
struct SubtitleSurface: View {
    let controller: SubtitleController
    let translation: TranslationService
    /// LLM 服务的模型列表(翻译方式菜单里快速选模型)。
    let catalog: LLMModelCatalog
    @Bindable var settings: AppSettings
    let permissions: Permissions
    let hovering: Bool
    /// 字幕运行时也可以听写(听写优先,字幕暂停解码,结束后补上)。
    let onDictate: () -> Void
    /// 打开字幕记录窗口(查看前面的全部字幕)。
    let onTranscript: () -> Void
    /// 打开 设置 › 实时字幕。
    let onTranslationSettings: () -> Void
    /// 配置某个在线翻译服务(弹出配置表单)。
    let onConfigureProvider: (TranslationProvider) -> Void
    /// 系统翻译的配置(下载语言包)。
    let onConfigureSystem: () -> Void
    /// 打开 设置 › AI 服务(配置 LLM 接口)。
    let onConfigureLLM: () -> Void
    let onCollapse: () -> Void
    let onStop: () -> Void

    /// 原文 / 译文字号(设置 › 实时字幕 分别调;标题栏的 小 / 大 两个一起调)。
    private var sourceSize: CGFloat { settings.subtitleSourceFontSize }
    private var translationSize: CGFloat { settings.subtitleTranslationFontSize }

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
        #if DEBUG
        // 调试用:IB_SHOW_HEADER=1 一直显示标题栏(检查翻译标签的排版,不用移动鼠标)。
        if ProcessInfo.processInfo.environment["IB_SHOW_HEADER"] != nil { return true }
        #endif
        return hovering
    }

    private var showsHeader: Bool { headerShown }

    /// 最宽:随字号变化,最多 940。
    private var maxWidth: CGFloat { min(max(max(sourceSize, translationSize) * 30, 540), 940) }

    /// 字幕条宽度:有字幕后固定为最大宽度——滚动字幕的换行位置依赖宽度,宽度一变整段就会重排跳动;
    /// 还没有字幕时用紧凑宽度。悬停时至少放得下标题栏。
    private var surfaceWidth: CGFloat {
        let hasText = controller.feed.captions.hasSource
        let content: CGFloat = controller.status == .running && hasText && !controller.silentTooLong ? maxWidth : 420
        // 标题栏多了翻译方式、原文行数两个标签时需要更宽一点。
        let headerMin: CGFloat = controller.translationEnabled ? 680 : 500
        return min(max(content, headerWidth ? headerMin : 200), maxWidth)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            LiveDot(level: controller.level, active: controller.status == .running)
            Text(controller.appName.isEmpty ? String(localized: "字幕", bundle: .l10n) : controller.appName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            TranslationTargetChip(controller: controller, settings: settings, onSettings: onTranslationSettings)
            if controller.translationEnabled {
                TranslationMethodChip(translation: translation, catalog: catalog, settings: settings,
                                      error: controller.feed.translationError,
                                      onConfigure: onConfigureProvider, onConfigureSystem: onConfigureSystem,
                                      onConfigureLLM: onConfigureLLM,
                                      onSettings: onTranslationSettings)
                SourceLinesChip(settings: settings)
            }
            Spacer(minLength: 12)
            if case .failed = controller.status {
                // 启动失败:没有可结束的字幕,只提供关闭(其他工具都没有意义)。
                tool("xmark", help: String(localized: "关闭", bundle: .l10n), action: onStop)
            } else {
                HStack(spacing: 2) {
                    tool("textformat.size.smaller", help: String(localized: "缩小字号（原文和译文一起）", bundle: .l10n)) { adjustFontSize(by: -2) }
                    tool("textformat.size.larger", help: String(localized: "放大字号（原文和译文一起）", bundle: .l10n)) { adjustFontSize(by: 2) }
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

    /// 字幕正文:滚动字幕(见 RollingCaptions)。翻译时原文(小、略暗)在上,跟着语音实时走;
    /// 译文(大、亮)在下,按句接上,还没定下来的暂定译文略暗。各一个固定最大行数的框(原文 0–3 行、译文 2–5 行,
    /// 设置 › 实时字幕 可调;行数多,一句译文停留得久,读得完),底部对齐,写满后最旧的一行整行滚出。
    /// 不翻译时原文 2 行大字。
    /// 左对齐:滚动字幕居中时每次增长整行都会左右移动,左对齐才稳定。
    /// 原文和提示不接收鼠标事件(超出框被裁掉的文字也不会挡住标题栏按钮);译文区可以滚动往回看(TranslationScrollView)。
    private var transcript: some View {
        let feed = controller.feed
        let captions = feed.captions
        let translating = feed.translating
        return VStack(alignment: .leading, spacing: translating || feed.unavailableReason != nil ? 4 : 0) {
            if !captions.hasSource {
                Text("等待声音…")
                    .font(.system(size: smallSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .allowsHitTesting(false)
            } else if translating {
                // 原文行数可设(0 = 不显示);译文还一个字都没有时,至少显示 1 行原文,字幕条不会空着。
                let sourceLines = captions.translation.isEmpty ? max(settings.subtitleSourceLines, 1) : settings.subtitleSourceLines
                if sourceLines > 0 {
                    rollingBox(Text(captions.sourceFinal).foregroundStyle(.white.opacity(0.6))
                               + Text(captions.sourceLive).foregroundStyle(.white.opacity(0.4)),
                               size: sourceSize, weight: .medium, lines: sourceLines)
                        .allowsHitTesting(false)
                }
                if !captions.translationLines.isEmpty {
                    // 译文区可以往回滚动(Apple Music 歌词式),所以接收鼠标事件。
                    // 原文区不显示时,原文已是目标语言的句子也在这里显示,不然这句就没了。
                    TranslationScrollView(lines: captions.translationLines, fontSize: translationSize,
                                          maxLines: settings.subtitleTranslationLines,
                                          showSameLanguage: sourceLines == 0)
                    // 翻译中途出错(额度用完、密钥失效):译文区还有内容,但后面的句子只会用原文顶上,
                    // 必须常驻说明原因,直到下一次翻译成功。
                    if let error = feed.translationError {
                        statusLine(String(localized: "翻译出错：\(error)。可在标题栏的翻译方式菜单里换一种方式。", bundle: .l10n),
                                   symbol: "exclamationmark.triangle.fill")
                    }
                } else if let error = feed.translationError {
                    statusLine(error, symbol: "exclamationmark.triangle.fill")
                } else if captions.translationWaiting {
                    Text("翻译中…")
                        .font(.system(size: smallSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            } else {
                rollingBox(Text(captions.sourceFinal).foregroundStyle(.white)
                           + Text(captions.sourceLive).foregroundStyle(.white.opacity(0.75)),
                           size: sourceSize, weight: .semibold, lines: 2)
                    .allowsHitTesting(false)
                // 打开了翻译但当前方式用不了(如语言包没下载、服务没配置):说明原因,在方式菜单里换一种即可。
                if let reason = feed.unavailableReason {
                    statusLine(String(localized: "无法翻译：\(reason)。把鼠标移到字幕条上，点翻译方式菜单即可配置或更换。", bundle: .l10n),
                               symbol: "exclamationmark.triangle.fill")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }

    /// 译文位置上的一行提示(出错、不可用)。
    private func statusLine(_ text: String, symbol: String) -> some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: symbol).foregroundStyle(DS.warning) }
            .font(.system(size: smallSize * 0.85, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(2)
    }

    /// 提示文字("等待声音…""翻译中…")的字号。
    private var smallSize: CGFloat { min(sourceSize, translationSize) * 0.9 }

    /// 原文和译文字号一起调,各自夹在范围内(一个到了边界,另一个还能继续调)。
    private func adjustFontSize(by delta: Double) {
        let range = AppSettings.subtitleFontRange
        settings.subtitleSourceFontSize = min(max(settings.subtitleSourceFontSize + delta, range.lowerBound), range.upperBound)
        settings.subtitleTranslationFontSize = min(max(settings.subtitleTranslationFontSize + delta, range.lowerBound), range.upperBound)
    }

    /// 最多 `lines` 行高的滚动框:文字按宽度自然换行,不足时按实际行数(刚开始不留空白),
    /// 超过时底部对齐、裁掉顶部多出的行。
    private func rollingBox(_ text: Text, size: CGFloat, weight: Font.Weight, lines: Int) -> some View {
        text
            .font(.system(size: size, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: Self.lineHeight(size: size, weight: weight) * CGFloat(lines), alignment: .bottom)
            // 不给高度提议,框就按文字的实际高度(不超过最大行数),而不是撑满最大高度留出空白。
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
