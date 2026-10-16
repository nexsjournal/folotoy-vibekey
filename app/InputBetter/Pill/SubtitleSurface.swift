import SwiftUI

/// 字幕条:胶囊展开后的形态。顶部是直播标记 + 应用名 + 翻译菜单(悬停时显示工具按钮);
/// 下面是迷你字幕记录:按时间从上到下排列,最新的在最下面,越旧越暗,超出高度的从顶部淡出——
/// 和字幕记录窗口的阅读方向一致,一眼能看出哪句是最新的。开启翻译时每句原文下面紧跟它的译文。
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(width: min(max(fontSize * 30, 540), 940), alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            LiveDot(level: controller.level, active: controller.status == .running)
            Text(controller.appName.isEmpty ? String(localized: "字幕", bundle: .l10n) : controller.appName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            translationMenu
            Spacer(minLength: 12)
            if case .failed = controller.status {
                // 启动失败:没有可结束的字幕,只提供关闭(其他工具都没有意义)。
                tool("xmark", help: String(localized: "关闭", bundle: .l10n), action: onStop)
            } else if hovering {
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
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
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

    /// 迷你字幕记录:最近几句 + 正在说的半句,底部对齐,高度固定(不随内容跳动),顶部渐隐。
    private var transcript: some View {
        let translating = settings.subtitleTranslate
        // 翻译时每句占两行(原文 + 译文),显示最近 2 句;不翻译时显示最近 3 句。再加正在说的半句。
        let entries = Array(controller.transcript.entries.suffix(translating ? 2 : 3))
        let partial = controller.partial
        return VStack(alignment: .leading, spacing: translating ? 10 : 6) {
            if entries.isEmpty && partial.isEmpty {
                Text("等待声音…")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(entry, age: entries.count - 1 - index + (partial.isEmpty ? 0 : 1), translating: translating)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !partial.isEmpty {
                // 正在说(未定稿):略暗,表示还会变;翻译时下面是系统翻译的实时译文。
                VStack(alignment: .leading, spacing: 2) {
                    Text(partial)
                        .font(.system(size: translating ? fontSize * 0.72 : fontSize, weight: translating ? .medium : .semibold))
                        .foregroundStyle(.white.opacity(translating ? 0.5 : 0.7))
                        .lineLimit(2)
                        .truncationMode(.head)
                    if translating, let live = controller.partialTranslation {
                        Text(live)
                            .font(.system(size: fontSize * 0.92, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .id("partial")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 高度固定(不随内容跳动),大约容纳上面的句数;个别句子折行超出时,最旧的从顶部渐隐。
        .frame(height: fontSize * (translating ? 6.4 : 4.6), alignment: .bottom)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)],
                             startPoint: .top, endPoint: .bottom))
        .animation(.spring(duration: 0.35, bounce: 0.1), value: entries.map(\.id))
        .animation(.easeOut(duration: 0.25), value: entries.map(\.translation))
    }

    /// 一句定稿字幕。`age` 0 = 最新,越旧越暗;翻译时原文较小,译文在下面且更醒目。
    private func row(_ entry: SubtitleController.Line, age: Int, translating: Bool) -> some View {
        let fade = max(0.35, 1 - Double(age) * 0.3)
        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
                .font(.system(size: translating ? fontSize * 0.72 : fontSize, weight: translating ? .medium : .semibold))
                .foregroundStyle(.white.opacity((translating ? 0.6 : 1) * fade))
                .lineLimit(2)
                .truncationMode(.head)
            if translating {
                Group {
                    if let translation = entry.translation {
                        // 空字符串:原文已是目标语言,不显示译文。初稿(系统翻译)略暗,AI 润色版替换后变亮。
                        if !translation.isEmpty {
                            Text(translation)
                                .foregroundStyle(.white.opacity((entry.translationIsDraft ? 0.8 : 1) * fade))
                                .contentTransition(.interpolate)
                        }
                    } else if entry.translationFailed {
                        Text("翻译失败").foregroundStyle(.white.opacity(0.35 * fade))
                    } else {
                        Text("翻译中…").foregroundStyle(.white.opacity(0.35 * fade))
                    }
                }
                .font(.system(size: fontSize * 0.92, weight: .semibold))
                .lineLimit(2)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
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
