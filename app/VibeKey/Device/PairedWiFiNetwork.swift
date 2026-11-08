import Foundation

/// 一台 Passport 已保存的一组网络。host 与 key 必须成对：切换 SSID 后设备会换一套
/// mDNS 主机名和 TLS-PSK，不能沿用旧网络的值。
nonisolated struct PairedWiFiNetwork: Codable, Equatable, Identifiable, Sendable {
    var ssid: String
    var host: String
    var keyHex: String

    var id: String { host }
    var displayName: String { ssid.isEmpty ? host : ssid }
    var key: Data? {
        guard keyHex.count == 64 else { return nil }
        var data = Data()
        data.reserveCapacity(32)
        var index = keyHex.startIndex
        for _ in 0..<32 {
            let end = keyHex.index(index, offsetBy: 2)
            guard let byte = UInt8(keyHex[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        return data
    }

    init(ssid: String, host: String, key: Data) {
        self.ssid = ssid
        self.host = host
        keyHex = key.map { String(format: "%02x", $0) }.joined()
    }
}

/// CredentialStore 只接受字符串，多网络列表以 JSON 字符串保存；旧版单条 host/key
/// 在首次读取时迁移成一组记录，不需要用户重新配网。
nonisolated enum PairedWiFiNetworkStore {
    static let networksKey = "passportLANNetworks"
    static let activeHostKey = "passportLANActiveHost"
    static let legacyHostKey = "passportLANHost"
    static let legacyKeyKey = "passportLANKey"

    static func load(from credentials: CredentialStore) -> [PairedWiFiNetwork] {
        if let raw = credentials.value(for: networksKey),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([PairedWiFiNetwork].self, from: data) {
            return decoded.filter { !$0.host.isEmpty && $0.key != nil }
        }
        guard let host = credentials.value(for: legacyHostKey), !host.isEmpty,
              let hex = credentials.value(for: legacyKeyKey), hex.count == 64,
              let data = Data(hexString: hex)
        else { return [] }
        return [PairedWiFiNetwork(ssid: "", host: host, key: data)]
    }

    static func save(_ networks: [PairedWiFiNetwork], activeHost: String, to credentials: CredentialStore) {
        if networks.isEmpty {
            credentials.set(nil, for: networksKey)
        } else if let data = try? JSONEncoder().encode(networks) {
            credentials.set(String(decoding: data, as: UTF8.self), for: networksKey)
        }
        credentials.set(activeHost.isEmpty ? nil : activeHost, for: activeHostKey)
        // 新结构写入后不继续保留重复密钥。
        credentials.set(nil, for: legacyHostKey)
        credentials.set(nil, for: legacyKeyKey)
    }

    static func activeHost(from credentials: CredentialStore, networks: [PairedWiFiNetwork]) -> String {
        if let host = credentials.value(for: activeHostKey),
           networks.contains(where: { $0.host == host }) {
            return host
        }
        return networks.first?.host ?? ""
    }
}

private extension Data {
    nonisolated init?(hexString: String) {
        guard hexString.count == 64 else { return nil }
        var data = Data()
        data.reserveCapacity(32)
        var index = hexString.startIndex
        for _ in 0..<32 {
            let end = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        self = data
    }
}
