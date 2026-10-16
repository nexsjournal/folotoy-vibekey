import SwiftUI

/// Passport 快速设置:左侧设备示意图,右侧按阶段显示
/// 「查找设备 → 刷入固件 → 按键测试 / 麦克风 / 蓝牙」。引导页和设置页共用。
struct PassportSetupView: View {
    let model: PassportSetupModel

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.l) {
            PassportIllustration(screen: illustrationScreen, connection: model.link.connection,
                                 foreignOnUSB: model.link.foreignDevice != nil, lastKey: model.link.lastKey,
                                 hints: model.deviceHints)
                .frame(width: 150)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                switch model.stage {
                case .searching: searching
                case .needsFirmware(let device): needsFirmware(device)
                case .flashing: flashingCard
                case .connected: connected
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.spring(duration: 0.35), value: model.stage)
        .onAppear { model.checkFirmware() }
        .onDisappear { model.stopMicTest() }
    }

    private var illustrationScreen: PassportIllustration.Screen {
        switch model.flasher.phase {
        case .downloading(let p): return .progress(p, "DOWNLOAD")
        case .backingUp(let p): return .progress(p, "BACKUP")
        case .flashing(let p): return .progress(p, "FLASHING")
        case .preparing, .restarting: return .progress(0, "WAIT")
        default: break
        }
        switch model.stage {
        case .searching: return .searching
        case .needsFirmware: return .update
        case .flashing: return .progress(0, "WAIT")
        case .connected: return .ready
        }
    }

    // MARK: - 查找设备

    private var searching: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.s + 2) {
                    Text("连接你的 Passport").font(.system(size: 14, weight: .semibold))
                    step(1, "长按电源键 0.5 秒开机")
                    step(2, "用支持数据传输的 USB-C 线连接这台 Mac")
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在查找设备…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            Hint("没有 Passport 也完全不影响使用，可以直接跳过，之后在 设置 › Passport 里再连接。")
        }
    }

    // MARK: - 刷固件

    private func needsFirmware(_ device: DeviceLink.ForeignDevice) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(spacing: 6) {
                        Text("发现 Passport").font(.system(size: 14, weight: .semibold))
                        Tag(text: "需要刷入 InputBetter 固件", color: DS.warning)
                    }
                    Text("当前运行的是「\(device.firmware ?? String(localized: "其他固件", bundle: .l10n))」。刷入 InputBetter 固件后，它才能配合听写、显示状态并提醒 Agent 进度。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        bullet("arrow.down.circle", "从官网下载最新固件，大约 1 分钟，期间不要拔线")
                        bullet("externaldrive.badge.checkmark", "第一次刷写会先把整片 Flash 备份到本机，随时可恢复原固件")
                        bullet("lock.shield", "只写入固件区域，不会改动设备身份数据")
                    }
                    .padding(.top, 2)
                    flashControls
                        .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var flashControls: some View {
        switch model.flasher.phase {
        case .idle, .done:
            if model.flasher.esptool == nil {
                Hint("这个版本的 app 缺少烧录工具，请重新安装 InputBetter，或在官网 input.0os.io 用浏览器刷入。")
            } else if case .incompatible(let manifest) = model.flasher.latest {
                Hint("官网的固件 \(manifest.version) 需要更新版本的 InputBetter，请先更新 app。")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let version = model.flasher.latestManifest?.version {
                        Button("刷入固件（\(version)）") { model.flashFirmware() }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("刷入固件") { model.flashFirmware() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    latestStatus
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(LocalizedStringKey(message), systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12)).foregroundStyle(DS.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") { model.flashFirmware() }.buttonStyle(SecondaryButtonStyle())
            }
        case .downloading(let p):
            progressRow("正在从官网下载固件", value: p)
        case .preparing:
            progressRow("正在进入下载模式…", value: nil)
        case .backingUp(let p):
            progressRow("正在备份原固件", value: p)
        case .flashing(let p):
            progressRow("正在写入固件", value: p)
        case .restarting:
            progressRow("正在重启设备…", value: nil)
        }
    }

    /// 刷写按钮下方的官网固件查询状态(查询失败不挡刷写,点刷入时会再请求)。
    @ViewBuilder
    private var latestStatus: some View {
        switch model.flasher.latest {
        case .checking:
            Text("正在从官网获取最新固件…").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .failed(let message):
            Text(verbatim: message).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private func progressRow(_ title: LocalizedStringKey, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                if let value { Text(verbatim: "\(Int(value * 100))%").font(.system(size: 12, weight: .semibold)).monospacedDigit() }
            }
            if let value {
                ProgressView(value: value).tint(DS.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(DS.accent)
            }
        }
    }

    /// 刷写过程中的进度卡片(新设备首次刷写与已连接设备更新共用)。
    private var flashingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("正在刷入 InputBetter 固件").font(.system(size: 14, weight: .semibold))
                Text("大约 1 分钟，期间不要拔线。").font(.system(size: 12)).foregroundStyle(.secondary)
                flashControls.padding(.top, 4)
            }
        }
    }

    /// 已连接时的固件行:版本、是否有新固件、更新 / 重新刷入。
    private var firmwareRow: some View {
        HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("固件 \(model.link.firmwareVersion ?? String(localized: "未知", bundle: .l10n))").font(.system(size: 13))
                    if model.firmwareUpdateAvailable { Tag(text: "有新固件", color: DS.accent) }
                }
                Text(firmwareDetail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.firmwareUpdateAvailable {
                Button("更新固件") { model.flashFirmware() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canReflash)
            } else {
                Button("重新刷入") { model.flashFirmware() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!model.canReflash)
            }
        }
    }

    private var firmwareDetail: String {
        if model.link.connection == .ble { return String(localized: "更新固件需要用 USB 连接", bundle: .l10n) }
        if case .failed(let message) = model.flasher.phase { return String(localized: "上次刷写失败：\(message)", bundle: .l10n) }
        switch model.flasher.latest {
        case .available(let latest) where model.firmwareUpdateAvailable:
            return String(localized: "官网有新版固件（\(latest.version) · \(latest.build)）", bundle: .l10n)
        case .available:
            return String(localized: "已是最新固件", bundle: .l10n)
        case .incompatible(let latest):
            return String(localized: "官网的固件 \(latest.version) 需要更新版本的 InputBetter", bundle: .l10n)
        case .checking, .unknown:
            return String(localized: "正在检查新固件…", bundle: .l10n)
        case .failed:
            return String(localized: "暂时无法连接官网检查新固件", bundle: .l10n)
        }
    }

    // MARK: - 已连接

    private var connected: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.success)
                        Text("Passport 已就绪").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(statusLine).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    if case .done(let backup?) = model.flasher.phase {
                        Hint("原固件已备份到 \(backup)")
                    }
                    Divider().padding(.vertical, 2)
                    firmwareRow
                    Divider().padding(.vertical, 2)
                    Text("按一下设备右侧的键试试，左边的示意图会跟着亮").font(.system(size: 12)).foregroundStyle(.secondary)
                    // 按实体键从上到下排列:上键、下键、OK 键。
                    VStack(alignment: .leading, spacing: 6) {
                        legend("chevron.up", "上键", model.upActionTitle)
                        legend("chevron.down", "下键", model.downActionTitle)
                        legend("circle.fill", "OK 键", String(localized: "按住说话，轻按免提", bundle: .l10n))
                    }
                    Hint("长按上键切换 听写 / 翻译 / 字幕；长按下键：\(model.downLongActionTitle)；录音时长按下键取消。")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("用 Passport 麦克风收音").font(.system(size: 13))
                            Text("关闭时按 OK 键用 Mac 的麦克风听写；开启后改用设备上的麦克风，适合离电脑稍远时使用").font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.usesPassportMic }, set: { model.usesPassportMic = $0 }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                    HStack(spacing: DS.Space.s) {
                        Button(model.micTesting ? LocalizedStringKey("停止") : LocalizedStringKey("测试麦克风")) { model.toggleMicTest() }
                            .buttonStyle(SecondaryButtonStyle())
                        LevelMeter(level: model.micLevel, active: model.micTesting)
                        if model.micTesting {
                            Text("对着设备说话").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许蓝牙连接").font(.system(size: 13))
                            Text("拔掉 USB 后自动改用蓝牙；第一次打开时系统会请求蓝牙权限").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.bluetoothAllowed }, set: { model.bluetoothAllowed = $0 }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    private var statusLine: String {
        let link = model.link
        var parts = [link.connection == .usb ? "USB" : String(localized: "蓝牙", bundle: .l10n)]
        if let b = link.batteryPercent { parts.append(String(localized: "电量 \(b)%", bundle: .l10n)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 小组件

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(n)")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(DS.accent))
            Text(text).font(.system(size: 12.5))
        }
    }

    private func bullet(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一行按键说明:键帽图标 + 键名 + 当前动作。
    private func legend(_ symbol: String, _ key: LocalizedStringKey, _ action: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 22, height: 14)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
            Text(key).font(.system(size: 12, weight: .medium)).frame(width: 52, alignment: .leading)
            Text(verbatim: action).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// 横向音量条:12 格,随音量点亮。
private struct LevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                let on = active && Float(i) / 12 < level
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(on ? AnyShapeStyle(DS.accent) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    .frame(width: 5, height: 12)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
