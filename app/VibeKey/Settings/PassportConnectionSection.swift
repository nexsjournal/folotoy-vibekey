import SwiftUI

/// Passport 真实连接状态:链路、最后在线、固件、电量。避免只看到设备上的
/// `WAITING FOR MAC` 时误以为 USB / Wi-Fi 已经正常。
struct PassportConnectionSection: View {
    let link: DeviceLink

    var body: some View {
        SettingsSection(title: "连接状态", footer: "设备 15 秒没收到 Mac 命令会进入 OFFLINE；USB 插着但设备显示 OFFLINE 时，点「重新连接」会重开串口，不需要拔线。") {
            Card {
                VStack(spacing: DS.Space.m) {
                    SettingRow(title: "当前链路") {
                        Label(connectionText, systemImage: connectionIcon)
                            .foregroundStyle(connectionColor)
                    }
                    Divider()
                    SettingRow(title: "最后在线") {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(lastSeenText(now: context.date))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    SettingRow(title: "固件") {
                        Text(firmwareText).foregroundStyle(.secondary)
                    }
                    Divider()
                    SettingRow(title: "电量") {
                        HStack(spacing: 6) {
                            if link.charging {
                                Image(systemName: "bolt.fill").foregroundStyle(DS.success)
                            }
                            Text(batteryText).foregroundStyle(.secondary)
                        }
                    }
                    if link.connection == .disconnected {
                        HStack {
                            Text(link.usbPortPath == nil
                                 ? "没有发现 USB 串口；请确认数据线支持传输。"
                                 : "USB 已发现，但还没有完成握手。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("重新连接") { link.resumeUSB() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var connectionText: String {
        switch link.connection {
        case .usb: String(localized: "USB", bundle: .l10n)
        case .wifi: String(localized: "Wi-Fi", bundle: .l10n)
        case .ble: String(localized: "蓝牙", bundle: .l10n)
        case .disconnected: String(localized: "未连接", bundle: .l10n)
        }
    }

    private var connectionIcon: String {
        switch link.connection {
        case .usb: "cable.connector"
        case .wifi: "wifi"
        case .ble: "dot.radiowaves.left.and.right"
        case .disconnected: "exclamationmark.triangle"
        }
    }

    private var connectionColor: Color {
        link.connection == .disconnected ? DS.danger : DS.success
    }

    private var firmwareText: String {
        guard let version = link.firmwareVersion else { return String(localized: "未知", bundle: .l10n) }
        if let build = link.firmwareBuild, !build.isEmpty {
            return "\(version) · \(build)"
        }
        return version
    }

    private var batteryText: String {
        guard let percent = link.batteryPercent else { return String(localized: "未知", bundle: .l10n) }
        var text = "\(percent)%"
        if link.charging { text += String(localized: " · 充电中", bundle: .l10n) }
        if let mv = link.batteryMillivolts {
            text += String(format: " · %.2f V", Double(mv) / 1000)
        }
        return text
    }

    private func lastSeenText(now: Date) -> String {
        guard let date = link.lastMessageDate else { return String(localized: "从未连接", bundle: .l10n) }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 2 { return String(localized: "刚刚", bundle: .l10n) }
        if seconds < 60 { return String(localized: "\(seconds) 秒前", bundle: .l10n) }
        if seconds < 3600 { return String(localized: "\(seconds / 60) 分钟前", bundle: .l10n) }
        return String(localized: "\(seconds / 3600) 小时前", bundle: .l10n)
    }
}
