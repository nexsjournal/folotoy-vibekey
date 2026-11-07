import Foundation

/// 各云服务配置的读写与"是否已配置"状态。界面编辑后立即保存;ModelManager / EngineRegistry 读取。
@MainActor @Observable
final class CloudASRStore {
    private(set) var configs: [CloudProvider: CloudConfig] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStore

    init(defaults: UserDefaults = .standard, credentials: CredentialStore = .shared) {
        self.defaults = defaults
        self.credentials = credentials
        for provider in CloudProvider.allCases {
            configs[provider] = CloudConfig(
                apiKey: credentials.value(for: Self.keyName(provider)) ?? "",
                model: defaults.string(forKey: "cloud.\(provider.rawValue).model") ?? provider.defaultModel,
                region: CloudRegion(rawValue: defaults.string(forKey: "cloud.\(provider.rawValue).region") ?? "") ?? .mainland,
                baseURL: defaults.string(forKey: "cloud.\(provider.rawValue).baseURL") ?? "https://api.openai.com/v1")
        }
    }

    func config(_ provider: CloudProvider) -> CloudConfig {
        configs[provider] ?? CloudConfig(apiKey: "", model: provider.defaultModel, region: .mainland, baseURL: "")
    }

    func isConfigured(_ provider: CloudProvider) -> Bool { config(provider).isComplete(for: provider) }

    func update(_ provider: CloudProvider, _ config: CloudConfig) {
        configs[provider] = config
        credentials.set(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keyName(provider))
        defaults.set(config.model, forKey: "cloud.\(provider.rawValue).model")
        defaults.set(config.region.rawValue, forKey: "cloud.\(provider.rawValue).region")
        defaults.set(config.baseURL, forKey: "cloud.\(provider.rawValue).baseURL")
    }

    /// 移除配置:删除本机保存的 API Key(其余设置保留,重新填 Key 即可恢复)。
    func remove(_ provider: CloudProvider) {
        var config = config(provider)
        config.apiKey = ""
        update(provider, config)
    }

    private static func keyName(_ provider: CloudProvider) -> String { "cloud.\(provider.rawValue).apiKey" }
}
