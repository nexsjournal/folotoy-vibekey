import SwiftUI

/// 字幕条上待确认的「结束字幕？」:由 `AppState.stopCaptions` 发起,挂在 `PillUIState.stopPrompt` 上,
/// 字幕条在 ⏹ 按钮上弹出 `StopCaptionsBubble`。记录的是发起时的那一场字幕(`session`),
/// 字幕换了一场后旧的询问作废,不会把新一场误结束。
struct StopCaptionsPrompt: Equatable {
    let appName: String
    let sentences: Int
    /// 发起时的 `CaptionTranscript.id`。
    let session: UUID
    /// 「不再询问」勾选状态(确认结束时才生效,见 `AppState.confirmStopCaptions`)。
    var dontAskAgain = false
}

/// 结束字幕的确认气泡:深色系统 popover(AnchoredPopover,小三角正对字幕条标题栏的 ⏹),
/// 排版仿 TipKit 的提示卡片:左边图标,右边标题 + 说明 + 操作。用户顺手就能点「结束」;
/// 点气泡以外的地方、Esc 都是取消。替代原来居中的模态提示框。
struct StopCaptionsBubble: View {
    let prompt: StopCaptionsPrompt
    @Binding var dontAskAgain: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "stop.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("结束字幕？")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(prompt.appName) · \(prompt.sentences) 句。结束后可以在字幕记录窗口里查看、总结和保存。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Toggle("不再询问", isOn: $dontAskAgain)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("取消", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("结束", action: onConfirm)
                        .buttonStyle(ProminentBubbleButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 330, alignment: .leading)
    }
}

/// 气泡里的「结束」按钮:状态条面板不抢焦点,气泡窗口在用户点进去之前也不是 key,
/// 系统的 borderedProminent 这时会显示成"非活动"的灰色,看不出哪个是默认操作,所以自己画成强调色胶囊。
private struct ProminentBubbleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 22)
            .background(Capsule().fill(Color.accentColor))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
