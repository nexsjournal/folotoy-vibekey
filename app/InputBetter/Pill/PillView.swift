import SwiftUI

/// 胶囊上的用户操作,由 AppState 注入实现,视图本身不包含业务逻辑。
struct PillActions {
    var toggleDictation: () -> Void
    /// 弹出应用列表选择字幕来源,参数为弹出位置(窗口坐标)。
    var startCaptions: (CGPoint) -> Void
    var expandCaptions: () -> Void
    var collapseCaptions: () -> Void
    /// 字幕条上的 ⏹:结束字幕(按设置先在 ⏹ 上方弹出「结束字幕？」气泡;气泡已显示时再点一次 = 收起气泡)。
    var stopCaptions: () -> Void
    /// 「结束字幕？」气泡里的 结束 / 取消。
    var confirmStopCaptions: () -> Void
    var cancelStopCaptions: () -> Void
    /// 打开字幕记录窗口。
    var showTranscript: () -> Void
    /// 字幕条「翻译设置…」:打开 设置 › 实时字幕(字幕的翻译方式在那里)。
    var openTranslationSettings: () -> Void
    /// 配置某个在线翻译服务(打开 设置 › 翻译服务 并弹出配置表单)。
    var configureTranslationProvider: (TranslationProvider) -> Void
    /// 打开 设置 › 翻译服务 并弹出系统翻译的配置(下载语言包)。
    var openSystemTranslation: () -> Void
    /// 打开 设置 › AI 服务(配置 LLM 服务)。
    var openLLMSettings: () -> Void
    /// 打开 设置 › 听写(听写翻译不可用、翻译 / 润色失败时点击结果胶囊)。
    var openDictationSettings: () -> Void
    /// 打开快捷菜单,参数为点击位置(窗口坐标)。
    var showMenu: (CGPoint) -> Void
    var cancel: () -> Void
    var confirm: () -> Void
    /// 关闭编程 Agent 通知。
    var dismissAgent: () -> Void
}

/// 胶囊状态条(与字幕条是同一个表面,所有形态之间用 Liquid Glass 变形过渡):
/// - 空闲:一条细小的玻璃胶囊;
/// - 悬停:裂变成「🎤」和「◉ ⌃」两组玻璃按钮;
/// - 字幕运行:胶囊展开成字幕条;听写时临时缩回录音胶囊,结束后再展开;
/// - 录音:波形 + 实时文字气泡;处理中:流光边框;完成 / 失败:图标卡片。
/// 整个表面可以拖动(按钮上的点击不受影响)。
struct PillView: View {
    let dictation: DictationController
    let subtitles: SubtitleController
    let agent: AgentNotifier
    let translation: TranslationService
    let catalog: LLMModelCatalog
    let ui: PillUIState
    let settings: AppSettings
    let permissions: Permissions
    let hotkeyHint: () -> String
    let actions: PillActions
    let window: PillWindowActions

    @Namespace private var glass
    /// 离开后延迟收起,避免鼠标擦过时闪烁。
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var tooltip: String?
    /// 长时间没有任何活动时淡下去(仍然可见),有活动立即恢复。
    @State private var dimmed = false
    /// 空闲多久后变淡(调试构建可用 IB_DIM_AFTER 秒数缩短,便于检查)。
    private var dimAfter: Duration {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["IB_DIM_AFTER"], let v = Double(s) { return .seconds(v) }
        #endif
        return .seconds(30)
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            bubble
            pill
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { _ in window.dragChanged() }
                    .onEnded { _ in window.dragEnded() })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    reportHotRect(rect)
                }
                .onChange(of: surface == .captionsBar && settings.subtitleLocked) { _, _ in reportHotRect(lastPillRect) }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.32, bounce: 0.18), value: stateKey)
        .animation(.spring(duration: 0.3, bounce: 0.12), value: expanded)
        .onChange(of: ui.isHovering) { _, inside in updateExpanded(inside) }
        // 状态、悬停、通知任一变化都算一次活动:先恢复亮度,再重新计时。
        .task(id: activityKey) {
            if dimmed { withAnimation(.easeOut(duration: 0.25)) { dimmed = false } }
            try? await Task.sleep(for: dimAfter)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.6)) { dimmed = true }
        }
    }

    /// 活动标识:变化即视为用户在使用。
    private var activityKey: String { "\(stateKey)-\(ui.isHovering)-\(expanded)" }

    @State private var lastPillRect: CGRect = .zero

    /// 回传可交互区域。空闲时胶囊很小,热区放大一些更容易悬停;字幕条锁定时整块穿透。
    private func reportHotRect(_ rect: CGRect) {
        lastPillRect = rect
        if surface == .captionsBar, settings.subtitleLocked {
            window.reportHotRect(.zero)
            return
        }
        let minW: CGFloat = 150, minH: CGFloat = 40
        window.reportHotRect(CGRect(x: rect.midX - max(rect.width, minW) / 2,
                                    y: rect.maxY - max(rect.height, minH),
                                    width: max(rect.width, minW), height: max(rect.height, minH)))
    }

    /// 当前形态(规则见 PillPresentation)。
    private var surface: PillSurface {
        let phase = dictation.phase
        var processing = false, result = false
        switch phase {
        case .processing: processing = true
        case .done, .failed: result = true
        default: break
        }
        return PillPresentation.surface(
            recording: phase == .starting || phase == .recording,
            processing: processing, showingResult: result,
            captionsRunning: subtitles.needsSurface, captionsCollapsed: ui.subtitleCollapsed,
            hovering: expanded, hasAgentNotice: agent.current != nil)
    }

    // MARK: - 状态

    /// 用于驱动动画的状态摘要。
    private var stateKey: String {
        switch dictation.phase {
        case .idle: "idle-\(surface)-\(agent.current?.event.rawValue ?? "")"
        case .starting, .recording: "rec-\(dictation.isHandsFree)"
        case .processing(let step): "proc-\(step)"
        case .done(let result): "done-\(result)"
        case .failed(let failure): "fail-\(failure)"
        }
    }


    private func updateExpanded(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            expanded = true
        } else {
            collapseTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { expanded = false; tooltip = nil }
            }
        }
    }

    // MARK: - 胶囊本体

    @ViewBuilder
    private var pill: some View {
        GlassEffectContainer(spacing: 12) {
            switch surface {
            case .captionsBar:
                // 正在问「结束字幕？」时标题栏保持显示:气泡挂在标题栏的 ⏹ 上,鼠标移进气泡也不能让它失去依托。
                SubtitleSurface(controller: subtitles, translation: translation, catalog: catalog, settings: settings, permissions: permissions,
                                hovering: expanded || ui.stopPrompt != nil, onDictate: actions.toggleDictation,
                                onTranscript: actions.showTranscript,
                                onTranslationSettings: actions.openTranslationSettings,
                                onConfigureProvider: actions.configureTranslationProvider,
                                onConfigureSystem: actions.openSystemTranslation,
                                onConfigureLLM: actions.openLLMSettings,
                                onCollapse: actions.collapseCaptions, onStop: actions.stopCaptions,
                                stopPrompt: stopPromptBinding, onConfirmStop: actions.confirmStopCaptions)
                    .glassEffect(.regular.tint(.black.opacity(0.55)), in: .rect(cornerRadius: 18))
                    .glassEffectID("main", in: glass)
            case .toolbar(let captions):
                toolbar(captions: captions)
            case .agentNotice:
                if let notice = agent.current { agentPill(notice) }
            case .capsule:
                idleCapsule
            case .recording:
                recordingPill
            case .processing:
                if case .processing(let step) = dictation.phase { processingPill(step.title) }
            case .result:
                switch dictation.phase {
                case .done(let result) where result.isWarning:
                    // 翻译 / 润色失败、已输入原文:警告色,点击打开听写设置。
                    resultPill(symbol: "exclamationmark.circle.fill", color: DS.warning, text: result.title,
                               action: actions.openDictationSettings)
                case .done(let result):
                    resultPill(symbol: "checkmark.circle.fill", color: DS.success, text: result.title)
                case .failed(let failure):
                    resultPill(symbol: "exclamationmark.triangle.fill", color: DS.danger, text: failure.title,
                               action: Self.opensDictationSettings(failure) ? actions.openDictationSettings : nil)
                default:
                    EmptyView()
                }
            }
        }
    }

    /// 空闲的细胶囊:缓慢呼吸,长时间不用时淡下去;字幕收起时更亮,表示字幕仍在运行。
    private var idleCapsule: some View {
        // 玻璃由 GlassEffectContainer 统一渲染,外层 opacity 不生效;变淡时内芯降低亮度、玻璃换成更通透的 clear 样式。
        IdleCapsule(subtitlesRunning: subtitles.isRunning, dimmed: dimmed)
            .glassEffect(dimmed ? .clear.tint(.black.opacity(0.15)) : .regular.tint(.black.opacity(0.45)), in: .capsule)
            .glassEffectID("main", in: glass)
    }

    /// 悬停展开:麦克风 + (字幕 / 菜单)两组按钮。
    /// ◉:没有字幕时弹出应用列表开始字幕;字幕在后台运行时展开字幕条。结束字幕在字幕条和 ⌃ 菜单里。
    private func toolbar(captions: CaptionsButton) -> some View {
        HStack(spacing: 10) {
            PillButton(symbol: "mic.fill", width: 46) { actions.toggleDictation() }
                .onHover { tooltip = $0 ? String(localized: "听写 · 按住 \(hotkeyHint()) 说话", bundle: .l10n) : nil }
                .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: .capsule)
                .glassEffectID("main", in: glass)

            HStack(spacing: 0) {
                switch captions {
                case .start:
                    AnchoredButton(symbol: "record.circle", width: 38) { point in actions.startCaptions(point) }
                        .onHover { tooltip = $0 ? String(localized: "实时字幕：选择应用", bundle: .l10n) : nil }
                case .expand:
                    PillButton(symbol: "captions.bubble.fill", width: 38) { actions.expandCaptions() }
                        .onHover { tooltip = $0 ? String(localized: "展开字幕条", bundle: .l10n) : nil }
                }
                AnchoredButton(symbol: "chevron.up", width: 30, size: 12) { point in actions.showMenu(point) }
                    .onHover { tooltip = $0 ? String(localized: "更多", bundle: .l10n) : nil }
            }
            .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: .capsule)
            .glassEffectID("tools", in: glass)
        }
    }

    /// 录音中:免提模式两侧有 ✕ / ✓,中间是波形。
    private var recordingPill: some View {
        HStack(spacing: 6) {
            if dictation.isHandsFree {
                PillButton(symbol: "xmark", width: 26, size: 11) { actions.cancel() }
                    .transition(.scale.combined(with: .opacity))
            } else {
                RecordingDot(color: DS.danger)
                    .padding(.leading, 6)
            }
            WaveformView(level: dictation.level, active: dictation.phase == .recording)
                .frame(width: dictation.isHandsFree ? 78 : 92, height: 22)
            if dictation.mode == .translate {
                Text("译")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1))
            }
            if dictation.isHandsFree {
                PillButton(symbol: "checkmark", width: 26, size: 11) { actions.confirm() }
                    .transition(.scale.combined(with: .opacity))
            } else {
                Spacer().frame(width: 6)
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 4)
        .glassEffect(.regular.tint(.black.opacity(0.5)), in: .capsule)
        .glassEffectID("main", in: glass)
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private func processingPill(_ label: String) -> some View {
        HStack(spacing: 8) {
            OrbitDots()
                .frame(width: 18, height: 18)
            ShimmerText(text: label)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassEffect(.regular.tint(.black.opacity(0.5)), in: .capsule)
        .glassEffectID("main", in: glass)
        .overlay(FlowingBorder())
    }

    /// 哪些失败点击后打开 设置 › 听写(用户能在那里解决的问题)。
    private static func opensDictationSettings(_ failure: DictationFailure) -> Bool {
        if case .translationUnavailable = failure { return true }
        return false
    }

    /// 完成 / 失败卡片。传入 `action` 时整个卡片可点击(末尾显示 › 提示),悬停有说明。
    @ViewBuilder
    private func resultPill(symbol: String, color: Color, text: String, action: (() -> Void)? = nil) -> some View {
        // 宽度跟着文字走、最长 492(加内边距共 520,长的失败说明截断)。
        // 不能用 frame(maxWidth:):面板给的宽度更大时它会撑满,短短的「已输入」也被拉成 520 宽。
        let content = CappedWidth(max: 492) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolEffect(.bounce, value: text)
                Text(text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .contentShape(Capsule())
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .help(Text("打开听写设置"))
                .accessibilityHint(Text("打开听写设置"))
                .glassEffect(.regular.tint(.black.opacity(0.5)).interactive(), in: .capsule)
                .glassEffectID("main", in: glass)
        } else {
            content
                .glassEffect(.regular.tint(.black.opacity(0.5)), in: .capsule)
                .glassEffectID("main", in: glass)
        }
    }

    /// 编程 Agent 通知:完成(绿)/ 等你确认(琥珀),点击关闭。
    private func agentPill(_ notice: AgentNotifier.Notice, glassID: String = "main") -> some View {
        let done = notice.event == .done
        let color = done ? DS.success : DS.warning
        return Button(action: actions.dismissAgent) {
            HStack(spacing: 7) {
                Image(systemName: done ? "checkmark.seal.fill" : "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, isActive: !done)
                Text(done ? String(localized: "\(notice.source) 完成了", bundle: .l10n) : String(localized: "\(notice.source) 在等你", bundle: .l10n))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.black.opacity(0.5)), in: .capsule)
        .glassEffectID(glassID, in: glass)
    }

    // MARK: - 「结束字幕？」气泡

    /// 字幕条读写的询问状态:置 nil(popover 被关掉)走 cancelStopCaptions,其他修改(「不再询问」)直接写回。
    private var stopPromptBinding: Binding<StopCaptionsPrompt?> {
        Binding(get: { ui.stopPrompt }, set: { new in
            if new == nil { if ui.stopPrompt != nil { actions.cancelStopCaptions() } } else { ui.stopPrompt = new }
        })
    }

    // MARK: - 气泡:实时文字 / 提示

    @ViewBuilder
    private var bubble: some View {
        if dictation.phase == .recording, !dictation.liveText.isEmpty {
            CappedWidth(max: 430) {
                Text(dictation.liveText)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.center)
                    .contentTransition(.interpolate)
            }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(.black.opacity(0.4)), in: .rect(cornerRadius: 14))
                .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.12), value: dictation.liveText)
        } else if surface == .captionsBar, let notice = agent.current {
            // 字幕条占着主表面时,Agent 通知浮在它上方。
            agentPill(notice, glassID: "agent")
                .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
        } else if case .toolbar = surface, let tooltip {
            Text(tooltip)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular.tint(.black.opacity(0.4)), in: .capsule)
                .transition(.opacity.combined(with: .offset(y: 4)))
        }
    }
}

// MARK: - 小组件

/// 胶囊里的圆形图标按钮。
private struct PillButton: View {
    let symbol: String
    var tint: Color = .white
    var width: CGFloat = 32
    var size: CGFloat = 14
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.85))
                .frame(width: width, height: 32)
                .contentShape(Capsule())
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// 需要点击位置的按钮(用于在按钮上方弹出 NSMenu,如 ⌃ 菜单、字幕应用列表)。
private struct AnchoredButton: View {
    let symbol: String
    var width: CGFloat = 32
    var size: CGFloat = 14
    let action: (CGPoint) -> Void
    @State private var frame: CGRect = .zero

    var body: some View {
        PillButton(symbol: symbol, width: width, size: size) {
            action(CGPoint(x: frame.midX, y: frame.minY - 4))
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// 按住说话时左侧的呼吸红点。
private struct RecordingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color, radius: on ? 5 : 1)
            .opacity(on ? 1 : 0.5)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { on = true } }
    }
}

/// 处理中:沿圆周旋转、带拖尾的小圆点。
private struct OrbitDots: View {

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 2
                for i in 0..<6 {
                    let angle = t * 4.2 - Double(i) * 0.42
                    let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                    let r = 2.2 - Double(i) * 0.25
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(0.95 - Double(i) * 0.14)))
                }
            }
        }
    }
}

/// 文字上掠过的高光。
private struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .overlay {
                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 40)
                        .offset(x: (phase - 0.5) * 120)
                        .mask(Text(text).font(.system(size: 12.5, weight: .semibold)))
                }
        }
    }
}

/// 沿胶囊边缘缓慢流动的一道淡白光。
private struct FlowingBorder: View {

    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2 * 360
            Capsule()
                .strokeBorder(
                    AngularGradient(colors: [.clear, .white.opacity(0.5), .white.opacity(0.15), .clear, .clear],
                                    center: .center, angle: .degrees(angle)),
                    lineWidth: 1.5)
        }
    }
}

/// 子视图宽度不超过 `max`,但内容短时按内容收缩(普通 frame(maxWidth:) 会撑满)。
private struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? max, max)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
