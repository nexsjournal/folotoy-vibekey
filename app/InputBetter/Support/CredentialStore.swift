import Foundation
import Security

/// 本机凭据(API Key 等)存储:`~/Library/Application Support/InputBetter/credentials.json`,文件权限 600。
/// 不用钥匙串:开发构建每次签名变化都会触发钥匙串授权弹窗,体验很差;权限 600 的配置文件是
/// 命令行与开发者工具存放用户自带密钥的通行做法。凭据只在本机,不会上传。
/// 线程安全(内部加锁),可在任意线程读写。写入时先以 600 权限新建临时文件、写好内容,再原子替换正式文件,
/// 文件在任何时刻都不会以宽松权限存在,也不会被写到一半;目录新建时为 700。
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

    /// 设置或删除(nil / 空字符串)一个凭据,立即写盘;值没有变化时不写盘(保存表单时各字段都会调用一次)。
    func set(_ value: String?, for key: String) {
        lock.withLock {
            var values = load()
            let newValue = value.flatMap { $0.isEmpty ? nil : $0 }
            guard values[key] != newValue else { return }
            values[key] = newValue
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

    /// 写盘:同目录下用 `open(O_CREAT | O_EXCL, 0600)` 新建临时文件(创建那一刻就是 600,不存在先宽后紧的窗口),
    /// 写入并落盘后再替换正式文件(同一卷上的替换是原子的)。
    /// 替换时只用新文件的元数据,避免沿用旧文件可能较宽的权限。失败只记日志(内存缓存仍是新值)。
    private func save(_ values: [String: String]) {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(values)
            try Self.writeNewPrivateFile(temp, data: data)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp, options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            Log.app.error("save credentials failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 新建一个只有本人可读写(0600)的文件并写入内容;文件已存在时失败(O_EXCL,不会误写别的文件)。
    private static func writeNewPrivateFile(_ url: URL, data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
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
