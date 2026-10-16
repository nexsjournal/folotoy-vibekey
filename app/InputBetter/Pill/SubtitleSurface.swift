import SwiftUI

/// 字幕条:胶囊展开后的形态。顶部是直播标记 + 应用名(悬停时显示工具按钮),下面是上一句(暗)、
/// 当前句(亮)和译文。背景玻璃由 PillView 统一加,以便和胶囊之间做变形动画。
struct SubtitleSurface: View {
    let controller: SubtitleController
    @Bindable var settings: AppSettings
    let permissions: Permissions
    let hovering: Bool
    /// 字幕运行时也可以听写(听写优先,字幕暂停解码,结束后补上)。
    let onDictate: () -> Void
    /// 打开字幕记录窗口(查看前面的全部字幕)。
    let onTranscript: () -> Void
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
        .animation(.spring(duration: 0.35, bounce: 0.15), value: controller.lines)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            LiveDot(level: controller.level, active: controller.status == .running)
            Text(controller.appName.isEmpty ? String(localized: "字幕", bundle: .l10n) : controller.appName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            if settings.subtitleTranslate {
                Text("译 · \(settings.subtitleTarget.title)")
                    .help(settings.subtitleTarget == .auto ? TargetLanguage.autoSummary : settings.subtitleTarget.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().strokeBorder(.white.opacity(0.2)))
            }
            Spacer(minLength: 12)
            if case .failed = controller.status {
                // 启动失败:没有可结束的字幕,只提供关闭(其他工具都没有意义)。
                tool("xmark", help: String(localized: "关闭", bundle: .l10n), action: onStop)
            } else if hovering {
                HStack(spacing: 2) {
                    tool("textformat.size.smaller", help: String(localized: "缩小字号", bundle: .l10n)) { settings.subtitleFontSize = max(14, fontSize - 2) }
                    tool("textformat.size.larger", help: String(localized: "放大字号", bundle: .l10n)) { settings.subtitleFontSize = min(44, fontSize + 2) }
                    tool(settings.subtitleTranslate ? "character.bubble.fill" : "character.bubble",
                         help: settings.llmConfigured ? String(localized: "显示译文（\(settings.subtitleTarget.title)）", bundle: .l10n) : String(localized: "翻译需要先配置 AI", bundle: .l10n)) {
                        settings.subtitleTranslate.toggle()
                    }
                    .disabled(!settings.llmConfigured)
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

    @ViewBuilder
    private var transcript: some View {
        if settings.subtitleTranslate {
            bilingual
        } else {
            sourceOnly
        }
    }

    /// 只显示原文:上一句(暗)+ 当前句(亮,正在说时略暗)。
    private var sourceOnly: some View {
        let lines = controller.lines
        let current = controller.partial.isEmpty ? lines.last?.text ?? "" : controller.partial
        let previous = controller.partial.isEmpty ? lines.dropLast().last : lines.last
        return VStack(alignment: .leading, spacing: 4) {
            if let previous {
                dimLine(previous.text).id("prev-\(previous.id)")
            }
            Text(current.isEmpty ? String(localized: "等待声音…", bundle: .l10n) : current)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(current.isEmpty ? 0.4 : controller.partial.isEmpty ? 1 : 0.86))
                .lineLimit(2)
                .truncationMode(.head)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.15), value: current)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 双语:上方暗色是正在说的内容;下面是同一句的原文和译文(译文最醒目)。
    /// 原文和译文始终对应同一句,译文没回来之前显示"翻译中…",不会出现原文和译文错位。
    private var bilingual: some View {
        let caption = controller.transcript.bilingual(partial: controller.partial)
        return VStack(alignment: .leading, spacing: 4) {
            if let live = caption.live, !live.isEmpty {
                dimLine(live)
            }
            if caption.source.isEmpty {
                Text("等待声音…")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                Text(caption.source)
                    .font(.system(size: fontSize * 0.78, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                Group {
                    if let translation = caption.translation {
                        Text(translation)
                            .foregroundStyle(.white)
                    } else if caption.failed {
                        Text("翻译失败")
                            .foregroundStyle(.white.opacity(0.4))
                    } else if caption.translating {
                        Text("翻译中…")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .contentTransition(.interpolate)
            }
        }
        .animation(.easeOut(duration: 0.2), value: caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dimLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize * 0.72, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
            .lineLimit(1)
            .truncationMode(.head)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
