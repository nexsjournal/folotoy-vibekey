import SwiftUI

/// 从右向左滚动的音量波形:每 45 ms 采样一次 `level`,白色竖条,左侧淡出。
struct WaveformView: View {
    let level: Float
    /// false 时(如正在打开麦克风)显示缓慢起伏的待机波形。
    let active: Bool

    @State private var history = WaveHistory()

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let samples = history.update(level: active ? level : 0, at: now, idle: !active)
            Canvas { ctx, size in
                let pitch: CGFloat = 4
                let barWidth: CGFloat = 2.2
                let count = Int(size.width / pitch)
                for i in 0..<count {
                    let index = samples.count - count + i
                    let value = index >= 0 ? CGFloat(samples[index]) : 0
                    let h = max(2.5, value * size.height)
                    let x = CGFloat(i) * pitch
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    // 左侧逐渐透明,产生滚入的纵深感。
                    let fade = min(1, Double(i) / Double(max(count / 3, 1)))
                    ctx.opacity = 0.25 + 0.75 * fade
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white))
                }
            }
        }
    }
}

/// 波形历史(引用类型,避免每帧触发 SwiftUI 状态更新)。
final class WaveHistory {
    private(set) var values: [Float] = Array(repeating: 0, count: 64)
    private var lastPush: TimeInterval = 0
    private var smoothed: Float = 0

    func update(level: Float, at time: TimeInterval, idle: Bool) -> [Float] {
        guard time - lastPush >= 0.045 else { return values }
        lastPush = time
        var v: Float
        if idle {
            v = 0.12 + 0.08 * Float(sin(time * 5))
        } else {
            // 响度曲线:小声也能看到起伏,大声不顶格;加一点随机抖动更生动。
            smoothed = smoothed * 0.4 + level * 0.6
            v = pow(smoothed, 0.8) * Float.random(in: 0.75...1.0)
        }
        values.append(min(max(v, 0), 1))
        if values.count > 64 { values.removeFirst(values.count - 64) }
        return values
    }
}
