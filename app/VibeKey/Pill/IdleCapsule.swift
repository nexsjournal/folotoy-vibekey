import SwiftUI

/// 空闲时的细胶囊(参考 betterwispr:36×6 的玻璃细条 + 1pt 细描边,没有内芯)。
/// 缓慢呼吸:描边和一层极淡的白色亮度轻微起伏(4 秒一个周期),用 Core Animation 循环动画实现,
/// 不逐帧重绘;系统开启"减少动态效果"时保持静止。
struct IdleCapsule: View {
    /// 字幕在后台运行:左侧显示小红点,提示仍在转录。
    let subtitlesRunning: Bool
    /// 长时间未使用:亮度降到约 45%,仍然可见。
    let dimmed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var inhale = false

    var body: some View {
        HStack(spacing: 0) {
            if subtitlesRunning {
                Circle().fill(DS.danger).frame(width: 4, height: 4).padding(.leading, 4)
                Spacer(minLength: 0)
            }
        }
        .frame(width: subtitlesRunning ? 44 : 36, height: 6)
        .background(Capsule().fill(Color.white.opacity(glow)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(stroke), lineWidth: 1))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { inhale = true }
        }
    }

    private var glow: Double { (inhale ? 0.12 : 0.04) * (dimmed ? 0.45 : 1) }
    private var stroke: Double {
        if contrast == .increased { return 0.6 }
        return (inhale ? 0.26 : 0.16) * (dimmed ? 0.45 : 1)
    }
}
