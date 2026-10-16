import SwiftUI

/// 空闲时的细胶囊内芯:缓慢呼吸(亮度轻微起伏,4 秒一个周期)。
/// 用 Core Animation 的循环动画实现,不逐帧重绘;系统开启"减少动态效果"时保持静止。
struct IdleCapsule: View {
    /// 字幕在后台运行时更亮一些,提示仍在工作。
    let subtitlesRunning: Bool
    /// 长时间未使用:亮度降到约 40%,仍然可见。
    let dimmed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inhale = false

    var body: some View {
        HStack(spacing: 5) {
            // 字幕在后台运行时显示小红点,提示仍在转录。
            if subtitlesRunning {
                Circle().fill(DS.danger).frame(width: 5, height: 5)
            }
            bar
        }
    }

    private var bar: some View {
        Capsule()
            .fill(Color.white.opacity((baseOpacity + (inhale ? 0.14 : 0)) * (dimmed ? 0.45 : 1)))
            .frame(width: subtitlesRunning ? 44 : 38, height: 6)
            .scaleEffect(x: inhale ? 1.04 : 1, y: 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { inhale = true }
            }
    }

    private var baseOpacity: Double { subtitlesRunning ? 0.5 : 0.18 }
}
