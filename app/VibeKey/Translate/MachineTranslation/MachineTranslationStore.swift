import Foundation

/// 在线翻译服务的凭据读写与"是否已配置"状态(写法同 CloudASRStore)。
/// 密钥存本机凭据文件(`translate.<服务>.key/secret`,权限 600),区域存 UserDefaults。
/// 不复用云端识别的火山 Key:识别用 API Key,翻译用 AK/SK,是两套凭据。
@MainActor @Observable
final class MachineTranslationStore {
    private(set) var all: [TranslationProvider: MTCredentials] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentialFile: CredentialStore

    init(defaults: UserDefaults = .standard, credentials: CredentialStore = .shared) {
        self.defaults = defaults
        credentialFile = credentials
        for provider in TranslationProvider.allCases {
            all[provider] = MTCredentials(
                key: credentials.value(for: Self.name(provider, .key)) ?? "",
                secret: credentials.value(for: Self.name(provider, .secret)) ?? "",
                region: defaults.string(forKey: Self.name(provider, .region)) ?? provider.defaultRegion)
        }
    }

    func credentials(_ provider: TranslationProvider) -> MTCredentials {
        all[provider] ?? MTCredentials(region: provider.defaultRegion)
    }

    func isConfigured(_ provider: TranslationProvider) -> Bool {
        credentials(provider).isComplete(for: provider)
    }

    /// 已配置的服务(按 TranslationProvider 的顺序)。
    var configured: [TranslationProvider] { TranslationProvider.allCases.filter(isConfigured) }

    func update(_ provider: TranslationProvider, _ value: MTCredentials) {
        let value = value.trimmed
        all[provider] = value
        credentialFile.set(value.key, for: Self.name(provider, .key))
        credentialFile.set(value.secret, for: Self.name(provider, .secret))
        defaults.set(value.region, forKey: Self.name(provider, .region))
    }

    /// 移除配置:删除本机保存的密钥(区域保留)。
    func remove(_ provider: TranslationProvider) {
        var value = credentials(provider)
        value.key = ""
        value.secret = ""
        update(provider, value)
    }

    private static func name(_ provider: TranslationProvider, _ field: CredentialField) -> String {
        "translate.\(provider.rawValue).\(field.rawValue)"
    }
}
