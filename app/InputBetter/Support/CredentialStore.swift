import Foundation
import Security

/// 本机凭据(API Key 等)存储:`~/Library/Application Support/InputBetter/credentials.json`,文件权限 600。
/// 不用钥匙串:开发构建每次签名变化都会触发钥匙串授权弹窗,体验很差;权限 600 的配置文件是
/// 命令行与开发者工具存放用户自带密钥的通行做法。凭据只在本机,不会上传。
/// 线程安全(内部加锁),可在任意线程读写;写入采用原子替换。
nonisolated final class CredentialStore: @unchecked Sendable {
    static let shared = CredentialStore()

    private let url: URL
    private let lock = NSLock()
    private var cache: [String: String]?

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InputBetter/credentials.json")) {
        self.url = url
    }

    func value(for key: String) -> String? {
        lock.withLock { load()[key] }
    }

    /// 设置或删除(nil / 空字符串)一个凭据,立即写盘。
    func set(_ value: String?, for key: String) {
        lock.withLock {
            var values = load()
            if let value, !value.isEmpty { values[key] = value } else { values.removeValue(forKey: key) }
            cache = values
            save(values)
        }
    }

    private func load() -> [String: String] {
        if let cache { return cache }
        let values = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = values
        return values
    }

    private func save(_ values: [String: String]) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(values)
            try data.write(to: url, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.app.error("save credentials failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 一次性迁移:早期版本把 LLM Key 存在钥匙串。静默读取(不弹授权框),迁移后删除钥匙串条目。
    func migrateFromKeychain(account: String, service: String = "com.inputbetter.InputBetter") {
        guard value(for: account) == nil else { return }
        let context = LAContextShim.skipUI
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query.merge(context) { $1 }
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty {
            set(text, for: account)
        }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

/// 读取钥匙串时禁止弹出授权界面(读不到就放弃,不打扰用户)。
private nonisolated enum LAContextShim {
    static var skipUI: [String: Any] {
        [kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
}
