import Foundation

/// USB 配网的唯一编码入口：按设备的 UTF-8 字节限制验证，不修改实际 SSID。
nonisolated struct WiFiProvisioning {
    let ssid: String
    let password: String
    let host: String
    let key: Data

    func encoded() throws -> Data {
        guard !ssid.isEmpty, ssid.utf8.count <= 32, !ssid.contains("\0"), !password.contains("\0"),
              password.isEmpty || (8...63).contains(password.utf8.count), key.count == 32,
              (4...31).contains(host.utf8.count),
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw Failure.invalid
        }
        let message: [String: Any] = ["cmd": "wifi", "ssid": ssid, "password": password, "host": host,
            "psk": key.map { String(format: "%02x", $0) }.joined()]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        guard data.count < 512 else { throw Failure.invalid }
        return data
    }

    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { String(localized: "Wi-Fi 名称或密码长度不正确", bundle: .l10n) }
    }
}

/// 设备对 `wifi` 配网命令的回应。只有确认收到配置后才允许把新密钥写入本机，
/// 否则设备回 `config_error` 时会留下「Mac 有新密钥、设备还是旧密钥」的永久错位。
nonisolated enum WiFiProvisioningAck {
    static func isRejected(stage: String) -> Bool {
        stage == "config_error" || stage == "network_error"
    }

    static func isAccepted(stage: String, host: String, pendingHost: String) -> Bool {
        guard !isRejected(stage: stage) else { return false }
        guard ["connecting", "ready", "auth_error", "not_found"].contains(stage) else { return false }
        // 首次配网时设备还没更新 s_config，host 为空也视为已收到配置。
        return host.isEmpty || host == pendingHost
    }
}
