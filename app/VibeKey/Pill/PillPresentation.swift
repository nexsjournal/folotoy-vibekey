import Foundation

/// 胶囊状态条的形态(纯函数推导,便于逐条测试交互规则)。
/// 规则(docs/architecture.md「胶囊与字幕交互」):
/// - 听写优先:录音 / 处理中 / 结果期间总是显示听写形态(字幕在后台继续采集);
/// - 字幕运行且展开:显示字幕条(悬停时字幕条上有 听写 / 收起 / 停止);
/// - 其余情况悬停显示工具条;◉ 在没有字幕时 = 选择应用开始字幕,字幕收起时 = 展开字幕条;
/// - 不悬停时:有 Agent 通知显示通知,否则显示细胶囊(字幕在后台运行时带红点)。
nonisolated enum PillSurface: Equatable, Sendable {
    case capsule(liveCaptions: Bool)
    case toolbar(captions: CaptionsButton)
    case captionsBar
    case agentNotice
    case recording
    case processing
    case result
}

/// 工具条上 ◉ 按钮的含义。
nonisolated enum CaptionsButton: Equatable, Sendable {
    /// 没有字幕:弹出应用列表,选中后开始字幕。
    case start
    /// 字幕在后台运行(已收起):展开字幕条。
    case expand
}

nonisolated enum PillPresentation {
    /// - Parameters:
    ///   - dictationBusy / processing / showingResult:听写的三个阶段(互斥)。
    static func surface(recording: Bool, processing: Bool, showingResult: Bool,
                        captionsRunning: Bool, captionsCollapsed: Bool,
                        hovering: Bool, hasAgentNotice: Bool) -> PillSurface {
        if recording { return .recording }
        if processing { return .processing }
        if showingResult { return .result }
        if captionsRunning, !captionsCollapsed { return .captionsBar }
        if hovering { return .toolbar(captions: captionsRunning ? .expand : .start) }
        if hasAgentNotice { return .agentNotice }
        return .capsule(liveCaptions: captionsRunning)
    }
}
