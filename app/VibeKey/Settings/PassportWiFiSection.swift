import SwiftUI

/// 首次使用 USB 把 Wi-Fi 凭据交给设备；配对后所有按键与音频都可走局域网加密链路。
struct PassportWiFiSection: View {
    let link: DeviceLink
    @State private var ssid = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        SettingsSection(title: "Wi-Fi 无线连接", footer: "首次配网请保留 USB 连接。选择 2.4 GHz Wi-Fi；设备和 Mac 连接同一局域网后，拔掉数据线即可使用。密码只经 USB 发给设备。") {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack {
                        Image(systemName: "wifi").foregroundStyle(link.wifiReady ? DS.success : Color.secondary)
                        Text(status)
                        Spacer()
                    }
                    TextField("Wi-Fi 名称", text: $ssid)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Wi-Fi 密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存并连接") {
                            do { try link.configureWiFi(ssid: ssid, password: password); password = ""; error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(link.usbPortPath == nil || ssid.isEmpty || (!password.isEmpty && !(8...63).contains(password.utf8.count)))
                        if link.wifiConfigured {
                            Button("清除 Wi-Fi 配对") { link.forgetWiFi() }
                                .disabled(link.usbPortPath == nil)
                        }
                        if link.usbPortPath == nil { Text("重新配网时需要 USB 连接").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(DS.danger) }
                }
            }
        }
        .onChange(of: link.wifiStatus?.ssid, initial: true) { _, name in
            if ssid.isEmpty, let name { ssid = name }
        }
    }

    private var status: LocalizedStringKey {
        if link.connection == .wifi { return "Wi-Fi 已连接" }
        if link.wifiReady { return "Wi-Fi 已就绪，拔线后自动切换" }
        switch link.wifiStatus?.stage {
        case "auth_error": return "Wi-Fi 密码验证失败，请重新配置"
        case "not_found": return "未找到 Wi-Fi，请检查名称和 2.4 GHz 网络"
        case "config_error", "network_error", "server_error": return "Wi-Fi 配置失败，请重新连接"
        case "ready": return "设备已入网，正在连接电脑"
        case "connecting": return "正在连接 Wi-Fi"
        default: return link.wifiConfigured ? "正在寻找已配对的设备" : "尚未配置 Wi-Fi"
        }
    }
}
