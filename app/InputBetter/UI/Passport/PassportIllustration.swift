import SwiftUI

/// Passport 示意图,按真实布局绘制:左上侧是电源键,右侧从上到下是 上键 / 下键 / OK 键。
/// 屏幕右边的按键提示贴着对应的实体键(与固件界面一致);按下真实设备的键时对应的侧键会亮起。
struct PassportIllustration: View {
    enum Screen: Equatable {
        case searching
        case update
        case progress(Double, String)
        case ready
    }

    let screen: Screen
    let connection: DeviceLink.Connection
    /// USB 上发现了设备但固件不对(还没建立 InputBetter 连接)。
    var foreignOnUSB = false
    /// 最近一次按键(id 变化时触发高亮动画)。
    let lastKey: (id: Int, key: DeviceKey, event: DeviceKeyEvent)?
    /// 屏幕右侧的按键提示图标(上键 / 下键 / OK 键),nil 则不显示。
    var hints = DeviceStateMapper.Hints(ok: nil, up: nil, down: nil)

    @State private var lit: DeviceKey?

    /// 机身尺寸与三个侧键的纵向位置(占机身高度的比例),和固件的提示位置对应。
    private let bodySize = CGSize(width: 132, height: 196)
    private let keyPositions: [(DeviceKey, CGFloat)] = [(.up, 0.24), (.down, 0.52), (.ok, 0.80)]

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // 侧键画在机身后面,只露出边缘。
                ForEach(keyPositions, id: \.0) { key, y in
                    sideKey(key)
                        .position(x: bodySize.width + 1, y: bodySize.height * y)
                }
                powerKey
                    .position(x: -1, y: bodySize.height * 0.18)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(white: 0.13))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1)))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    .frame(width: bodySize.width, height: bodySize.height)
                    .position(x: bodySize.width / 2, y: bodySize.height / 2)
                screenView
                    .frame(width: bodySize.width - 22, height: bodySize.height - 26)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06)))
                    .position(x: bodySize.width / 2, y: bodySize.height / 2)
            }
            .frame(width: bodySize.width, height: bodySize.height)
            .padding(.horizontal, 6)
            connectionBadge
        }
        .onChange(of: lastKey?.id) { _, _ in
            guard let key = lastKey?.key else { return }
            withAnimation(.easeOut(duration: 0.08)) { lit = key }
            Task {
                try? await Task.sleep(for: .milliseconds(260))
                withAnimation(.easeIn(duration: 0.25)) { lit = nil }
            }
        }
    }

    // MARK: - 机身按键

    private func sideKey(_ key: DeviceKey) -> some View {
        let on = lit == key
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(on ? Color.white : Color(white: 0.32))
            .frame(width: 8, height: 26)
            .offset(x: on ? -1 : 0)
    }

    private var powerKey: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color(white: 0.32))
            .frame(width: 8, height: 18)
    }

    // MARK: - 屏幕

    @ViewBuilder
    private var screenView: some View {
        switch screen {
        case .searching:
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                    .frame(width: 30 + 20 * (t.truncatingRemainder(dividingBy: 1.6) / 1.6))
                    .opacity(1 - t.truncatingRemainder(dividingBy: 1.6) / 1.6)
            }
        case .update:
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.circle").font(.system(size: 24)).foregroundStyle(.white.opacity(0.85))
                Text(verbatim: "UPDATE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
            }
        case .progress(let value, let label):
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                    Circle().trim(from: 0, to: max(0.02, value))
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: value)
                    Text(verbatim: "\(Int(value * 100))%").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
                Text(verbatim: label).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            }
        case .ready:
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1.5).frame(width: 44, height: 44)
                            Image(systemName: "mic.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        }
                        Text(verbatim: "DICTATE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(width: geo.size.width - 30, height: geo.size.height)
                    // 右侧提示列,纵向位置对应实体侧键(屏幕在机身里有 13pt 的上边距)。
                    ForEach(keyPositions, id: \.0) { key, y in
                        if let icon = hint(for: key) {
                            HStack(spacing: 1) {
                                Image(systemName: icon.sfSymbol).font(.system(size: 8, weight: .semibold))
                                Text(verbatim: "›").font(.system(size: 7, weight: .bold))
                            }
                            .foregroundStyle(lit == key ? .white : .white.opacity(0.45))
                            .position(x: geo.size.width - 11, y: bodySize.height * y - 13)
                        }
                    }
                }
            }
        }
    }

    private func hint(for key: DeviceKey) -> DeviceIcon? {
        switch key {
        case .up: hints.up
        case .down: hints.down
        case .ok: hints.ok
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            switch connection {
            case .usb:
                Image(systemName: "cable.connector")
                Text(verbatim: "USB")
            case .ble:
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("蓝牙")
            case .disconnected where foreignOnUSB:
                Image(systemName: "cable.connector")
                Text("USB · 待刷固件")
            case .disconnected:
                Image(systemName: "bolt.horizontal.circle")
                Text("未连接")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(connection != .disconnected ? DS.success : foreignOnUSB ? DS.warning : Color.secondary)
    }
}
