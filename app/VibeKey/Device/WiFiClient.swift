import Foundation
import Network
import Security

/// 已经通过 USB 配对的局域网连接。TLS-PSK 双向认证和加密，无云端服务；每次失败自动重连。
@MainActor @Observable
final class WiFiClient {
    private(set) var host: String
    private(set) var ready = false
    private let credentials: CredentialStore
    private let queue = DispatchQueue(label: "local.folobutton.wifi")
    private var connection: NWConnection?
    private var retry: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var enabled = false
    private var generation = 0
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onDisconnected: (() -> Void)?
    /// 连接在 ready 之前就失败（TLS-PSK 不匹配、设备未启动服务等），用于区分「设备不在线」和「密钥不对」。
    var onConnectFailure: (() -> Void)?

    init(credentials: CredentialStore) {
        self.credentials = credentials
        host = credentials.value(for: "passportLANHost") ?? ""
    }
    var configured: Bool { !host.isEmpty && key != nil }
    private var key: Data? {
        guard let hex = credentials.value(for: "passportLANKey"), hex.count == 64 else { return nil }
        var data = Data()
        var index = hex.startIndex
        for _ in 0..<32 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte); index = next
        }
        return data
    }
    func pair(host: String, key: Data) {
        disconnect()
        self.host = host
        credentials.set(host, for: "passportLANHost")
        credentials.set(key.map { String(format: "%02x", $0) }.joined(), for: "passportLANKey")
        if enabled { connect() }
    }
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled { if connection == nil { connect() } } else { disconnect() }
    }
    func forget() {
        disconnect()
        host = ""
        credentials.set(nil, for: "passportLANHost")
        credentials.set(nil, for: "passportLANKey")
    }
    func disconnect() {
        generation += 1
        retry?.cancel(); retry = nil
        timeout?.cancel(); timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        let wasReady = ready
        ready = false
        if wasReady { onDisconnected?() }
    }
    func send(_ data: Data) {
        guard ready, let connection else { return }
        let current = generation
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { Task { @MainActor in self?.lost(generation: current) } }
        })
    }
    private func connect() {
        guard enabled, let key, !host.isEmpty else { return }
        retry?.cancel(); retry = nil
        generation += 1
        let current = generation
        let tls = NWProtocolTLS.Options()
        let identity = Data("folobutton".utf8)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // PSK 套件尚未暴露到新的 tls_ciphersuite_t 枚举，使用仍受支持的 Security 兼容入口。
        // ECDHE 提供前向保密，ChaCha20-Poly1305 提供加密与完整性保护。
        sec_protocol_options_add_tls_ciphersuite(tls.securityProtocolOptions, SSLCipherSuite(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))
        let connection = NWConnection(host: .init(host + ".local"), port: 8765, using: NWParameters(tls: tls))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                switch state {
                case .ready: self.timeout?.cancel(); self.timeout = nil; self.ready = true; self.onReady?(); self.receive(generation: current)
                case .failed, .cancelled: self.lost(generation: current)
                default: break
                }
            }
        }
        connection.start(queue: queue)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, !self.ready else { return }
            self.lost(generation: current)
        }
    }
    private func receive(generation current: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                if let data, !data.isEmpty { self.onData?(data) }
                if complete || error != nil { self.lost(generation: current) }
                else { self.receive(generation: current) }
            }
        }
    }
    private func lost(generation current: Int) {
        guard current == generation else { return }
        let wasReady = ready
        disconnect()
        if !wasReady { onConnectFailure?() }
        guard enabled else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }
}
