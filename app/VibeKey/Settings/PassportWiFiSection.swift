import SwiftUI

/// 首次使用 USB 把 Wi-Fi 凭据交给设备；配对后所有按键与音频都可走局域网加密链路。
struct PassportWiFiSection: View {
    let link: DeviceLink
    @State private var ssid = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        SettingsSection(title: "Wi-Fi 无线连接", footer: "最多保存 4 个网络。首次添加请保留 USB；长按 ▲ 约 1 秒切换听写、翻译和字幕，继续按住到约 2.5 秒切换网络或蓝牙。蓝牙模式或离线时长按 ▼ 也可打开网络列表。密码只经 USB 发给设备。") {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack {
                        Image(systemName: "wifi").foregroundStyle(link.wifiReady ? DS.success : Color.secondary)
                        Text(status)
                        Spacer()
                        if let rssi = link.wifiStatus?.rssi, rssi != 0 {
                            Text("信号 \(rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(rssi < -75 ? DS.danger : Color.secondary)
                        }
                        if let count = link.wifiStatus?.count, count > 0 {
                            Text("设备已存 \(count)/4").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let rssi = link.wifiStatus?.rssi, rssi != 0, rssi < -75 {
                        Text("热点信号较弱：靠近手机，iPhone 请打开「最大兼容性」以使用 2.4 GHz。")
                            .font(.caption).foregroundStyle(DS.danger)
                    }
                    if !link.wifiNetworks.isEmpty {
                        Divider()
                        ForEach(link.wifiNetworks) { network in
                            networkRow(network)
                        }
                        Text("设备端：长按 ▲ 约 1 秒切换听写、翻译和字幕，继续到约 2.5 秒打开网络列表；蓝牙模式或离线时长按 ▼ 也可打开。短按上下选择，短按 OK 切换；最后一项 USE BLUETOOTH 可直接切蓝牙。长按 OK 返回。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    TextField("Wi-Fi 名称", text: $ssid)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Wi-Fi 密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("添加并切换") {
                            do { try link.configureWiFi(ssid: ssid, password: password); password = ""; error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(link.usbPortPath == nil || ssid.isEmpty || (!password.isEmpty && !(8...63).contains(password.utf8.count)))
                        if link.wifiConfigured {
                            Button("改用蓝牙") {
                                do { try link.useBluetooth(); error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                            .disabled(!canManage || link.connection == .ble)
                            Button("清除全部 Wi-Fi") { link.forgetWiFi() }
                                .disabled(link.usbPortPath == nil)
                        }
                        if link.usbPortPath == nil { Text("重新配网时需要 USB 连接").font(.caption).foregroundStyle(.secondary) }
                    }
                    if link.wifiConfigured {
                        Text("改用蓝牙不会删除已存网络；之后在设备上长按 ▲ 约 1 秒切换模式，继续按住到约 2.5 秒选择 Wi‑Fi 即可切回。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(DS.danger) }
                    if link.wifiHandshakeFailed {
                        Text("保持 USB 连接，重新输入 Wi-Fi 密码并点「添加并切换」；或点「改用蓝牙」跳过 Wi-Fi。")
                            .font(.caption).foregroundStyle(DS.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func networkRow(_ network: PairedWiFiNetwork) -> some View {
        let current = link.wifiActiveSSID == network.ssid || link.wifiStatus?.ssid == network.ssid
        HStack(spacing: DS.Space.s) {
            Image(systemName: current ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(current ? DS.success : Color.secondary)
            Text(network.displayName).lineLimit(1)
            if current {
                Text("当前").font(.caption2).foregroundStyle(DS.success)
            }
            Spacer()
            if !current {
                Button("切换") {
                    do { try link.selectWiFi(ssid: network.ssid); error = nil }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!canManage)
                Button {
                    do { try link.removeWiFi(ssid: network.ssid); error = nil }
                    catch { self.error = error.localizedDescription }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DS.danger)
                .disabled(!canManage)
            }
        }
    }

    private var status: LocalizedStringKey {
        if link.connection == .wifi { return "Wi-Fi 已连接" }
        if link.connection == .ble { return "蓝牙已连接（暂停 Wi-Fi）" }
        if link.wifiReady { return "Wi-Fi 已就绪，拔线后自动切换" }
        if link.wifiHandshakeFailed { return "设备已入网，但加密握手失败，请用 USB 重新配网" }
        switch link.wifiStatus?.stage {
        case "auth_error": return "Wi-Fi 密码验证失败，请重新配置"
        case "not_found": return "未找到 Wi-Fi，请检查名称和 2.4 GHz 网络"
        case "config_error", "network_error", "server_error": return "Wi-Fi 配置失败，请重新连接"
        case "ready": return "设备已入网，正在连接电脑"
        case "connecting": return "正在连接 Wi-Fi"
        default: return link.wifiConfigured ? "正在寻找已配对的设备" : "尚未配置 Wi-Fi"
        }
    }

    private var canManage: Bool { link.connection != .disconnected }
}
