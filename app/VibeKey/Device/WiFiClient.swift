import Foundation
import Network
import Security

/// 已经通过 USB 配对的局域网连接。TLS-PSK 双向认证和加密，无云端服务；每次失败自动重连。
///
/// 设备可能保存多组 Wi-Fi，并在硬件上切换当前网络。Mac 同时尝试所有已保存的
/// `host.local`，第一个完成 TLS 握手的记录就是设备当前网络；这样不依赖 USB 回报状态。
@MainActor @Observable
final class WiFiClient {
    private(set) var host: String
    private(set) var networks: [PairedWiFiNetwork]
    private(set) var activeSSID: String
    private(set) var ready = false
    private let credentials: CredentialStore
    private let queue = DispatchQueue(label: "local.folobutton.wifi")
    private var connection: NWConnection?
    private var attempts: [NWConnection] = []
    private var preferredHost: String
    private var retry: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var enabled = false
    private var generation = 0
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onDisconnected: (() -> Void)?
    /// 所有记录都在 ready 之前失败（设备不在线、TLS-PSK 不匹配等），用于区分「设备不在线」和「密钥不对」。
    var onConnectFailure: (() -> Void)?

    init(credentials: CredentialStore) {
        self.credentials = credentials
        let loaded = PairedWiFiNetworkStore.load(from: credentials)
        networks = loaded
        let activeHost = PairedWiFiNetworkStore.activeHost(from: credentials, networks: loaded)
        preferredHost = activeHost
        let active = loaded.first { $0.host == activeHost } ?? loaded.first
        host = active?.host ?? ""
        activeSSID = active?.ssid ?? ""
    }

    var configured: Bool { !networks.isEmpty }

    /// 新增或覆盖一组网络。设备确认收到配置后才调用，避免两边 PSK 错位。
    func pair(ssid: String, host: String, key: Data) {
        disconnect()
        networks.removeAll { $0.host == host || (!ssid.isEmpty && $0.ssid == ssid) }
        networks.append(PairedWiFiNetwork(ssid: ssid, host: host, key: key))
        preferredHost = host
        self.host = host
        activeSSID = ssid
        persist()
        if enabled { connect() }
    }

    /// 设备回报当前网络（USB 状态或设备端切换后）时，把连接目标切到匹配的本地凭据。
    func activate(ssid: String, host: String) {
        guard let matched = networks.first(where: { !host.isEmpty && $0.host == host })
                ?? networks.first(where: { !ssid.isEmpty && $0.ssid == ssid })
        else { return }
        var changed = false
        if !ssid.isEmpty, matched.ssid != ssid,
           let index = networks.firstIndex(where: { $0.host == matched.host }) {
            networks[index].ssid = ssid
            changed = true
        }
        if preferredHost != matched.host || self.host != matched.host {
            changed = true
            disconnect()
            preferredHost = matched.host
            self.host = matched.host
            activeSSID = matched.ssid.isEmpty ? ssid : matched.ssid
            if enabled { connect() }
        } else {
            activeSSID = matched.ssid.isEmpty ? ssid : matched.ssid
        }
        if changed { persist() }
    }

    func remove(ssid: String) {
        guard networks.contains(where: { $0.ssid == ssid }) else { return }
        let wasActive = networks.first(where: { $0.host == preferredHost })?.ssid == ssid
        networks.removeAll { $0.ssid == ssid }
        if networks.isEmpty {
            disconnect()
            host = ""
            activeSSID = ""
            preferredHost = ""
        } else if wasActive || !networks.contains(where: { $0.host == preferredHost }) {
            disconnect()
            preferredHost = networks[0].host
            host = networks[0].host
            activeSSID = networks[0].ssid
            if enabled { connect() }
        }
        persist()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            if connection == nil, attempts.isEmpty, retry == nil { connect() }
        } else {
            disconnect()
        }
    }

    func reconnectIfNeeded() {
        guard enabled, connection == nil, attempts.isEmpty else { return }
        retry?.cancel()
        retry = nil
        connect()
    }

    func forget() {
        disconnect()
        networks = []
        host = ""
        activeSSID = ""
        preferredHost = ""
        persist()
    }

    func disconnect() {
        generation += 1
        retry?.cancel(); retry = nil
        timeout?.cancel(); timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        for candidate in attempts {
            candidate.stateUpdateHandler = nil
            candidate.cancel()
        }
        attempts = []
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

    private func persist() {
        PairedWiFiNetworkStore.save(networks, activeHost: preferredHost, to: credentials)
    }

    private func connect() {
        guard enabled, !networks.isEmpty else { return }
        retry?.cancel(); retry = nil
        generation += 1
        let current = generation
        for network in networks {
            guard let key = network.key else { continue }
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
            let candidate = NWConnection(host: .init(network.host + ".local"), port: 8765, using: NWParameters(tls: tls))
            attempts.append(candidate)
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let candidate else { return }
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    switch state {
                    case .ready:
                        self.choose(candidate, network: network, generation: current)
                    case .failed, .cancelled:
                        self.fail(candidate, generation: current)
                    default:
                        break
                    }
                }
            }
            candidate.start(queue: queue)
        }
        guard !attempts.isEmpty else { return }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, !self.ready else { return }
            self.lost(generation: current)
        }
    }

    private func choose(_ candidate: NWConnection, network: PairedWiFiNetwork, generation current: Int) {
        guard current == generation else { candidate.cancel(); return }
        guard connection == nil else { candidate.stateUpdateHandler = nil; candidate.cancel(); return }
        timeout?.cancel(); timeout = nil
        connection = candidate
        for other in attempts where other !== candidate {
            other.stateUpdateHandler = nil
            other.cancel()
        }
        attempts = []
        preferredHost = network.host
        host = network.host
        activeSSID = network.ssid
        persist()
        ready = true
        onReady?()
        receive(generation: current)
    }

    private func fail(_ candidate: NWConnection, generation current: Int) {
        guard current == generation else { return }
        if connection === candidate {
            connection = nil
            lost(generation: current)
            return
        }
        attempts.removeAll { $0 === candidate }
        if connection == nil, attempts.isEmpty { lost(generation: current) }
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
