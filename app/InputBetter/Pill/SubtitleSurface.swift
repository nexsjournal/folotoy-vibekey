import AppKit
import SwiftUI

/// 字幕条:胶囊展开后的形态。顶部是直播标记 + 应用名 + 翻译菜单(悬停时显示工具按钮);
/// 下面是滚动字幕(业内通行的 roll-up 形式,见 RollingCaption):原文、译文各固定 2 行,
/// 新内容接在末尾,旧行整行滚出顶部,最新的永远在右下角。
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

    /// 滚动字幕(见 RollingCaption):原文和译文各一个固定 2 行的框,底部对齐,超出的旧行从顶部整行滚出。
    /// 翻译时原文小而暗、译文大而亮(译文在下,离视线最近);不翻译时只显示原文。
    /// 定稿部分正常颜色,正在说 / 实时译文部分略暗,表示还会变。
    private var transcript: some View {
        let translating = settings.subtitleTranslate
        let caption = RollingCaption.make(entries: controller.transcript.entries,
                                          partial: controller.partial,
                                          partialTranslation: translating ? controller.partialTranslation : nil)
        return VStack(alignment: .leading, spacing: translating ? 6 : 0) {
            if !caption.hasSource {
                rollingBox(Text("等待声音…").foregroundStyle(.white.opacity(0.4)),
                           size: fontSize, weight: .semibold, lines: translating ? 1 : 2)
            } else if translating {
                rollingBox(styled(caption.sourceFinal, caption.sourceLive, opacity: 0.62),
                           size: fontSize * 0.72, weight: .medium, lines: 2)
                rollingBox(caption.hasTranslation
                           ? styled(caption.translationFinal, caption.translationLive, opacity: 1)
                           : Text("翻译中…").foregroundStyle(.white.opacity(0.35)),
                           size: fontSize, weight: .semibold, lines: 2)
            } else {
                rollingBox(styled(caption.sourceFinal, caption.sourceLive, opacity: 1),
                           size: fontSize, weight: .semibold, lines: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 定稿 + 未定稿(略暗)拼成一段文字。
    private func styled(_ final: String, _ live: String, opacity: Double) -> Text {
        Text(final).foregroundStyle(.white.opacity(opacity)) + Text(live).foregroundStyle(.white.opacity(opacity * 0.62))
    }

    /// 固定行数的滚动框:文字按宽度自然换行,框高 = 行高 × 行数,底部对齐并裁掉顶部多出的行。
    private func rollingBox(_ text: Text, size: CGFloat, weight: Font.Weight, lines: Int) -> some View {
        text
            .font(.system(size: size, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.lineHeight(size: size, weight: weight) * CGFloat(lines), alignment: .bottom)
            .clipped()
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }

    /// 系统字体在该字号下的行高(与 SwiftUI Text 的默认行距一致),用来让框高正好是整数行。
    private static func lineHeight(size: CGFloat, weight: Font.Weight) -> CGFloat {
        let nsWeight: NSFont.Weight = switch weight {
        case .semibold: .semibold
        case .medium: .medium
        case .bold: .bold
        default: .regular
        }
        return ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: size, weight: nsWeight)))
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
