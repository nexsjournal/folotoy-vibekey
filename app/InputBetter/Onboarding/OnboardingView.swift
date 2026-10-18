import KeyboardShortcuts
import SwiftUI

/// 首次引导:欢迎 → 权限 → 模型 → 快捷键 → AI → 试一试。
/// 每一步都可以返回;权限和模型以外的步骤都可以跳过。
struct OnboardingView: View {
    let app: AppState
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, permissions, model, hotkey, ai, passport, tryIt

        var title: String {
            switch self {
            case .welcome: ""
            case .permissions: String(localized: "授予权限", bundle: .l10n)
            case .model: String(localized: "选择识别模型", bundle: .l10n)
            case .hotkey: String(localized: "设置说话快捷键", bundle: .l10n)
            case .ai: String(localized: "翻译与 AI（可选）", bundle: .l10n)
            case .passport: String(localized: "连接 Passport（可选）", bundle: .l10n)
            case .tryIt: String(localized: "试一试", bundle: .l10n)
            }
        }

        var subtitle: String {
            switch self {
            case .welcome: ""
            case .permissions: String(localized: "麦克风用来听你说话，辅助功能用来把文字输入到当前窗口。", bundle: .l10n)
            case .model: String(localized: "所有识别都在本机完成，声音不会离开你的 Mac。可以随时在设置里切换。", bundle: .l10n)
            case .hotkey: String(localized: "默认是 ⌥ 空格，点录制框可以改成你顺手的组合键。", bundle: .l10n)
            case .ai: String(localized: "下载系统翻译语言即可离线翻译字幕和听写；再连接 AI，还能润色口语、让译文更准确。", bundle: .l10n)
            case .passport: String(localized: "FoloToy AI Passport 是 InputBetter 的硬件搭档：按住说话、一键发送，Agent 完成时提醒你。", bundle: .l10n)
            case .tryIt: String(localized: "把光标放进下面的输入框，按住快捷键说一句话。", bundle: .l10n)
            }
        }
    }

    @State private var step: Step = Self.initialStep
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome { header }
            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .frame(width: 680, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { app.permissions.startPolling() }
        .onDisappear { app.permissions.stopPolling() }
    }

    /// 调试用:环境变量 IB_ONBOARDING_STEP=N 直接打开第 N 步,便于逐页检查界面。
    private static var initialStep: Step {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["IB_ONBOARDING_STEP"], let n = Int(raw), let s = Step(rawValue: n) { return s }
        #endif
        return .welcome
    }

    // MARK: - 头部:进度 + 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 6) {
                ForEach(Step.allCases.dropFirst(), id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(DS.accent) : AnyShapeStyle(Color.primary.opacity(0.1)))
                        .frame(height: 4)
                }
            }
            .animation(.easeOut(duration: 0.3), value: step)
            .padding(.bottom, DS.Space.s)
            Text(step.title).font(.system(size: 22, weight: .bold))
            Text(step.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.top, 40)
        .padding(.bottom, DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 每一步的内容

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep(language: app.language)
        case .permissions: permissionsStep
        case .model:
            ScrollView {
                // 只列本地模型:这一步的说明是"所有识别都在本机完成",云端识别留到 设置 › 识别模型 里再配置。
                ModelList(models: app.models, cloud: app.cloudASR, selection: Bindable(app.settings).dictationModelID,
                          items: ModelCatalog.all.filter { $0.cloudProvider == nil })
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, DS.Space.m)
            }
            .scrollIndicators(.never)
        case .hotkey:
            ShortcutsCard(settings: app.settings)
                .padding(.horizontal, DS.Space.xl)
        case .ai:
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Card { SystemTranslationRows(translation: app.translation, settings: app.settings) }
                    Text("AI（OpenAI 兼容接口）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, DS.Space.s)
                    LLMConfigForm(settings: app.settings, catalog: app.llmModels)
                    Toggle("听写后自动润色（去口水词、补标点、修正错字）", isOn: Bindable(app.settings).polishEnabled)
                        .font(.system(size: 12.5))
                        .disabled(!app.settings.llmConfigured)
                }
                .padding(.horizontal, DS.Space.xl)
            }
        case .passport:
            ScrollView {
                PassportSetupView(model: app.passportSetup)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, DS.Space.m)
            }
            .scrollIndicators(.never)
            .onAppear { app.unlockBluetooth() }
        case .tryIt:
            TryItStep(app: app)
                .padding(.horizontal, DS.Space.xl)
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: DS.Space.s) {
            PermissionRow(symbol: "mic.fill",
                          title: "麦克风", detail: "听你说话。录音只在按下快捷键时进行。",
                          granted: app.permissions.microphone == .authorized) { app.permissions.requestMicrophone() }
            PermissionRow(symbol: "keyboard.fill",
                          title: "辅助功能", detail: "监听快捷键，并把文字粘贴到当前光标处。",
                          granted: app.permissions.accessibility, buttonTitle: "去开启") { app.permissions.requestAccessibility() }
            Card {
                HStack(spacing: DS.Space.m) {
                    GradientIcon(symbol: "speaker.wave.2.fill", size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("系统音频录制").font(.system(size: 13.5, weight: .semibold))
                        Text("实时字幕需要。第一次打开字幕时系统会询问，现在不用设置。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("稍后").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, DS.Space.xl)
    }

    // MARK: - 底部按钮

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("返回") { go(-1) }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            if let note = footerNote {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Button(primaryTitle) {
                step == .tryIt ? onFinish() : go(1)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canContinue)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.l)
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome: "开始设置"
        case .ai where !app.settings.llmConfigured && !app.translation.systemReady: "跳过"
        case .passport where app.passportSetup.stage != .connected: "跳过"
        case .tryIt: "完成"
        default: "继续"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .passport:
            // 刷固件过程中不能离开这一步。
            !app.firmware.phase.isRunning
        case .model:
            // 选中的模型已安装或正在下载即可继续,下载在后台完成。
            switch app.models.state(app.settings.dictationModelID) {
            case .installed, .downloading: true
            default: false
            }
        default: true
        }
    }

    private var footerNote: LocalizedStringKey? {
        switch step {
        case .permissions where !app.permissions.allRequiredGranted: "没有这两项权限，听写无法工作"
        case .model where !canContinue: "请下载一个模型"
        case .model:
            if case .downloading = app.models.state(app.settings.dictationModelID) { "可以继续，下载会在后台完成" } else { nil }
        default: nil
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { step = next }
    }
}

// MARK: - 欢迎页

private struct WelcomeStep: View {
    let language: LanguageState
    @State private var appeared = false

    var body: some View {
        VStack(spacing: DS.Space.l) {
            HStack {
                Spacer()
                LanguagePicker(language: language)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.top, 36)
            HeroOrb()
                .frame(width: 128, height: 128)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: DS.Space.s) {
                Text("InputBetter").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("说话，就是最快的输入。识别全部在本机完成。")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .offset(y: appeared ? 0 : 12)
            .opacity(appeared ? 1 : 0)
            HStack(spacing: DS.Space.m) {
                feature("mic.fill", "按住说话", "在任何输入框里说话打字")
                feature("captions.bubble.fill", "实时字幕", "给任意应用的声音配字幕")
                feature("keyboard.badge.ellipsis", "Passport", "硬件按键，专为 vibe coding")
            }
            .padding(.horizontal, DS.Space.xl)
            .offset(y: appeared ? 0 : 20)
            .opacity(appeared ? 1 : 0)
            Spacer()
        }
        .onAppear { withAnimation(.spring(duration: 0.8, bounce: 0.3).delay(0.1)) { appeared = true } }
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 欢迎页的主视觉:深色圆形玻璃 + 跳动的白色波形(和 App 图标一致)。
private struct HeroOrb: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(Color(white: 0.12))
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    .padding(14)
                HStack(spacing: 5) {
                    ForEach(0..<5) { i in
                        let phase = t * 4 + Double(i) * 0.9
                        Capsule()
                            .fill(.white)
                            .frame(width: 6, height: 14 + 26 * abs(sin(phase)) * (i == 2 ? 1 : 0.75))
                    }
                }
            }
        }
    }
}

// MARK: - 试一试

private struct TryItStep: View {
    let app: AppState
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Card {
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .frame(height: 150)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("按住 \(app.hotkeys.dictateDescription) 说「今天天气不错，我们去散步吧」")
                                .font(.system(size: 15))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
            HStack(spacing: DS.Space.s) {
                Image(systemName: "lightbulb.fill").foregroundStyle(DS.warning)
                Hint("屏幕底部的小胶囊是 InputBetter 的状态条，鼠标移上去可以开始听写或打开实时字幕。")
            }
            .onAppear { app.showPill() }
            if app.deviceLink.connection != .disconnected {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(DS.success)
                    Hint("已连接 Passport：按住中间的 OK 键说话，上键回车、下键 Esc。")
                }
            }
        }
    }
}
