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
