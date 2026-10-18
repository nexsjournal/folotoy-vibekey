import AppKit
import AppUpdateInstaller
import AppUpdateKit
import SwiftUI

/// 新版本提示窗口的内容(WindowManager.showUpdate 创建窗口)。两种形态:
/// - 可选更新:下载并安装 / 稍后提醒 / 跳过此版本;
/// - 强制更新(当前版本已停止支持):只有 下载并安装 / 退出 InputBetter,窗口不能关闭。
///
/// 配置了 Sparkle(`installer` 不为 nil)时在 app 内下载、校验签名、安装并重启,进度显示在窗口里;
/// 没配置时「下载更新」在浏览器中打开安装包,并提示手动替换。
///
/// 布局:顶部主视觉(图标 + 标题 + 「旧版本 → 新版本」),中间是逐条排版的更新内容,底部操作栏。
/// 只显示信息、转发用户的选择,不做业务判断(是否强制由 UpdateChecker 决定)。
struct UpdatePromptView: View {
    let release: UpdateRelease
    let required: Bool
    let currentVersion: AppVersion
    /// 当前界面语言代码,用来挑选更新说明的语言。
    let languageCode: String
    /// 应用内安装(Sparkle);nil 时在浏览器中下载。
    let installer: SparkleInstaller?
    /// 在浏览器中打开安装包(没有 installer 时的主操作,也是安装失败时的兜底)。
    let onDownload: () -> Void
    let onLater: () -> Void
    let onSkip: () -> Void
    let onQuit: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 在浏览器中下载过:提示下一步怎么装。
    @State private var downloadStarted = false
    @State private var appeared = false

    /// 主色:可选更新用系统强调色,强制更新用提醒色。
    private var tint: Color { required ? DS.warning : DS.accent }

    var body: some View {
        VStack(spacing: 0) {
            hero
            notesSection
            footer
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.78)) { appeared = true }
        }
    }

    // MARK: - 主视觉

    private var hero: some View {
        let latest = release.version.description, current = currentVersion.description
        return VStack(spacing: DS.Space.m) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .shadow(color: tint.opacity(0.45), radius: 18, y: 6)
                    .accessibilityHidden(true)
                if required {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, DS.warning)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-2))
                        .offset(x: 6, y: 4)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(appeared ? 1 : 0.86)
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 6) {
                Text(required ? "需要更新 InputBetter" : "InputBetter 有新版本")
                    .font(.system(size: 20, weight: .semibold))
                Text(required ? "当前版本已停止支持，更新后才能继续使用。" : "新版本已经发布，建议更新以获得最新功能和修复。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DS.Space.s) {
                VersionChip(text: current, prominent: false, tint: tint)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                VersionChip(text: latest, prominent: true, tint: tint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("从 \(current) 更新到 \(latest)"))

            if let date = release.publishedAt {
                Text("发布于 \(date.formatted(.dateTime.year().month().day().locale(locale)))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 34)
        .padding(.bottom, DS.Space.l)
        .padding(.horizontal, DS.Space.xl)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { HeroGlow(tint: tint, animate: !reduceMotion) }
    }

    // MARK: - 更新内容

    @ViewBuilder private var notesSection: some View {
        let lines = ReleaseNoteLine.parse(release.notes(for: languageCode))
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !lines.isEmpty {
                Text("更新内容")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(lines) { line in
                            switch line.kind {
                            case .bullet:
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Circle().fill(tint).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2.5 }
                                    Text(verbatim: line.text).font(.system(size: 13))
                                }
                            case .heading:
                                Text(verbatim: line.text).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
                            case .text:
                                Text(verbatim: line.text).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 190)
                .fixedSize(horizontal: false, vertical: true)
                .background(DS.cardFill, in: RoundedRectangle(cornerRadius: DS.Radius.card - 2))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card - 2).stroke(DS.cardStroke))
            }

            if let installer, installer.phase != .idle {
                InstallProgressView(phase: installer.phase, tint: tint, onBrowserDownload: onDownload)
            } else {
                Label {
                    Text(installer != nil
                         ? "下载后会校验安装包签名，自动替换并重新打开 InputBetter，设置和模型都会保留。"
                         : downloadStarted
                         ? "已在浏览器中下载。下载完成后打开安装包，把 InputBetter 拖到「应用程序」替换旧版，再重新打开。"
                         : "下载后打开安装包，把 InputBetter 拖到「应用程序」替换旧版即可，设置和模型都会保留。")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: downloadStarted ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(downloadStarted ? DS.success : Color.secondary)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .animation(.easeOut(duration: 0.2), value: downloadStarted)
            }
        }
        .padding(.horizontal, DS.Space.xl - 4)
        .padding(.bottom, DS.Space.l)
    }

    // MARK: - 操作栏

    private var footer: some View {
        let phase = installer?.phase ?? .idle
        return HStack(spacing: DS.Space.s) {
            if required {
                Button("退出 InputBetter", action: onQuit).buttonStyle(SecondaryButtonStyle())
            } else if !phase.isBusy {
                Button("跳过此版本", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .downloading = phase {
                Button("取消") { installer?.cancel() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            } else if !required && !phase.isBusy {
                Button("稍后提醒", action: onLater)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Button(action: primaryAction) {
                Label(primaryTitle(phase), systemImage: phase == .waitingToQuit ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")
            }
            .buttonStyle(UpdateDownloadButtonStyle(tint: tint))
            .disabled(phase.isBusy)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Space.xl - 4)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .top) { Divider() }
    }

    /// 主按钮:有 Sparkle 时应用内安装(失败后重试 / 等待退出后继续),否则在浏览器中下载。
    private func primaryAction() {
        if let installer {
            installer.install()
        } else {
            onDownload()
            downloadStarted = true
        }
    }

    private func primaryTitle(_ phase: SparkleInstaller.Phase) -> LocalizedStringKey {
        guard installer != nil else { return downloadStarted ? "重新下载" : "下载更新" }
        switch phase {
        case .idle: return "下载并安装"
        case .checking, .downloading: return "正在下载…"
        case .extracting: return "正在校验…"
        case .installing: return "正在安装…"
        case .waitingToQuit: return "继续安装"
        case .failed: return "重试"
        }
    }
}

/// 应用内安装的进度:连接 / 下载(字节数)/ 校验解压 / 安装 / 等待退出 / 失败(附「在浏览器中下载」兜底)。
private struct InstallProgressView: View {
    let phase: SparkleInstaller.Phase
    let tint: Color
    let onBrowserDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch phase {
            case .failed(let reason):
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("安装没有完成：\(reason)").fixedSize(horizontal: false, vertical: true)
                        Button("改为在浏览器中下载", action: onBrowserDownload).buttonStyle(.link)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.warning)
                }
                .font(.system(size: 12))
            case .waitingToQuit:
                Label("InputBetter 还没有退出（例如实时字幕还在进行）。处理好后点「继续安装」。", systemImage: "pause.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            default:
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if let detail { Text(verbatim: detail).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary) }
                }
                if let fraction {
                    ProgressView(value: fraction).tint(tint)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(tint)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: phase)
    }

    private var title: LocalizedStringKey {
        switch phase {
        case .checking: "正在连接更新服务器…"
        case .downloading: "正在下载"
        case .extracting: "正在校验签名并解压…"
        case .installing: "正在安装，InputBetter 会自动重新打开…"
        default: ""
        }
    }

    private var fraction: Double? {
        switch phase {
        case .downloading(let received, let expected?) where expected > 0: min(1, Double(received) / Double(expected))
        case .extracting(let progress) where progress > 0: progress
        default: nil
        }
    }

    private var detail: String? {
        guard case .downloading(let received, let expected) = phase else { return nil }
        let format = ByteCountFormatter()
        format.countStyle = .file
        guard let expected else { return format.string(fromByteCount: Int64(received)) }
        return "\(format.string(fromByteCount: Int64(received))) / \(format.string(fromByteCount: Int64(expected)))"
    }
}

// MARK: - 组件

/// 版本号胶囊:旧版本是浅灰描边,新版本用主色填充。
private struct VersionChip: View {
    let text: String
    let prominent: Bool
    let tint: Color

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
            .overlay(Capsule().stroke(Color.primary.opacity(prominent ? 0 : 0.1)))
    }
}

/// 主视觉背后的柔光:主色径向渐变,缓慢呼吸(「减少动态效果」时静止)。
private struct HeroGlow: View {
    let tint: Color
    let animate: Bool
    @State private var breathing = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(breathing ? 0.34 : 0.22), .clear], center: .init(x: 0.5, y: 0.28),
                           startRadius: 4, endRadius: breathing ? 230 : 190)
        }
        .frame(height: 260)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard animate else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

/// 「下载更新」按钮:比通用主按钮更醒目(带图标、主色渐变、柔和投影)。
private struct UpdateDownloadButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(Capsule().fill(tint.gradient))
            .shadow(color: tint.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 8, y: 3)
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 更新说明的一行:以 `- ` / `* ` / `• ` 开头的是列表项,`#` 开头的是小标题,其余是普通段落;空行忽略。
struct ReleaseNoteLine: Identifiable, Equatable {
    enum Kind: Equatable { case bullet, heading, text }
    let id: Int
    let kind: Kind
    let text: String

    static func parse(_ notes: String) -> [ReleaseNoteLine] {
        var result: [ReleaseNoteLine] = []
        for raw in notes.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let kind: Kind, text: String
            if let marker = ["- ", "* ", "• "].first(where: line.hasPrefix) {
                kind = .bullet
                text = String(line.dropFirst(marker.count))
            } else if line.hasPrefix("#") {
                kind = .heading
                text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else {
                kind = .text
                text = line
            }
            if !text.isEmpty { result.append(ReleaseNoteLine(id: result.count, kind: kind, text: text)) }
        }
        return result
    }
}
