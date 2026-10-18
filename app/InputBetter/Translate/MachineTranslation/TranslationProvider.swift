import Foundation

/// 在线机器翻译服务商。每家的接口实现在 `Providers/`,语言代码见 `ProviderLanguageCodes`,
/// 凭据由 `MachineTranslationStore` 保存。选择标准:中英等主流语言效果好、有免费额度、个人开发者能直接申请。
nonisolated enum TranslationProvider: String, CaseIterable, Identifiable, Sendable {
    case deepl, google, azure, volcengine, tencent, baidu

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepl: "DeepL"
        case .google: String(localized: "Google 翻译", bundle: .l10n)
        case .azure: String(localized: "微软翻译", bundle: .l10n)
        case .volcengine: String(localized: "火山引擎翻译", bundle: .l10n)
        case .tencent: String(localized: "腾讯云翻译", bundle: .l10n)
        case .baidu: String(localized: "百度翻译", bundle: .l10n)
        }
    }

    /// 字幕条上的简称(越短越好)。
    var shortName: String {
        switch self {
        case .deepl: "DeepL"
        case .google: "Google"
        case .azure: String(localized: "微软", bundle: .l10n)
        case .volcengine: String(localized: "火山", bundle: .l10n)
        case .tencent: String(localized: "腾讯", bundle: .l10n)
        case .baidu: String(localized: "百度", bundle: .l10n)
        }
    }

    var detail: String {
        switch self {
        case .deepl: String(localized: "欧洲语言和中英互译都很自然，口语化表达处理得好", bundle: .l10n)
        case .google: String(localized: "Google Cloud Translation，语种最全，速度快", bundle: .l10n)
        case .azure: String(localized: "Azure AI Translator，稳定、免费额度大", bundle: .l10n)
        case .volcengine: String(localized: "字节跳动出品，中英互译质量好，国内访问快", bundle: .l10n)
        case .tencent: String(localized: "腾讯云机器翻译，免费额度最大，国内访问快", bundle: .l10n)
        case .baidu: String(localized: "百度翻译开放平台，国内访问快", bundle: .l10n)
        }
    }

    /// 免费额度说明(以服务商官网为准)。
    var freeTier: String {
        switch self {
        case .deepl: String(localized: "免费版每月 50 万字符（Key 以 :fx 结尾）", bundle: .l10n)
        case .google: String(localized: "每月前 50 万字符免费（需要开通结算）", bundle: .l10n)
        case .azure: String(localized: "F0 免费层每月 200 万字符", bundle: .l10n)
        case .volcengine: String(localized: "每月 200 万字符免费", bundle: .l10n)
        case .tencent: String(localized: "每月 500 万字符免费", bundle: .l10n)
        case .baidu: String(localized: "标准版每月 5 万字符免费，认证后 100 万", bundle: .l10n)
        }
    }

    /// 申请密钥的页面。
    var consoleURL: URL {
        switch self {
        case .deepl: URL(string: "https://www.deepl.com/your-account/keys")!
        case .google: URL(string: "https://console.cloud.google.com/apis/credentials")!
        case .azure: URL(string: "https://portal.azure.com/#create/Microsoft.CognitiveServicesTextTranslation")!
        case .volcengine: URL(string: "https://console.volcengine.com/iam/keymanage")!
        case .tencent: URL(string: "https://console.cloud.tencent.com/cam/capi")!
        case .baidu: URL(string: "https://fanyi-api.baidu.com/manage/developer")!
        }
    }

    /// 配置表单要填的字段(按显示顺序)。
    var fields: [CredentialField] {
        switch self {
        case .deepl, .google: [.key]
        case .azure: [.key, .region]
        case .volcengine, .baidu: [.key, .secret]
        case .tencent: [.key, .secret, .region]
        }
    }

    /// 可选的区域(有列表时用下拉框,否则是输入框)。
    var regions: [String] {
        switch self {
        case .tencent: ["ap-beijing", "ap-shanghai", "ap-guangzhou", "ap-chengdu", "ap-hongkong", "ap-singapore", "ap-seoul", "ap-tokyo", "na-siliconvalley", "eu-frankfurt"]
        default: []
        }
    }

    var defaultRegion: String {
        switch self {
        case .tencent: "ap-beijing"
        default: ""
        }
    }

    /// 字段的标签(各家控制台里的叫法,用户照着找)。
    func label(for field: CredentialField) -> String {
        switch (self, field) {
        case (.deepl, .key): "Auth Key"
        case (.google, .key): "API Key"
        case (.azure, .key): String(localized: "密钥", bundle: .l10n)
        case (.volcengine, .key): "Access Key ID"
        case (.volcengine, .secret): "Secret Access Key"
        case (.tencent, .key): "SecretId"
        case (.tencent, .secret): "SecretKey"
        case (.baidu, .key): "APP ID"
        case (.baidu, .secret): String(localized: "密钥", bundle: .l10n)
        case (_, .region): String(localized: "区域", bundle: .l10n)
        default: field.rawValue
        }
    }

    /// 是否按密码框显示:密钥类字段隐藏;ID 类字段(APP ID、SecretId、Access Key ID)明文显示,方便核对。
    func isSecret(_ field: CredentialField) -> Bool {
        switch field {
        case .secret: true
        case .key: fields.count == 1 || self == .azure
        case .region: false
        }
    }

    /// 字段是否必填(微软的全局资源可以不填区域)。
    func isRequired(_ field: CredentialField) -> Bool {
        !(self == .azure && field == .region)
    }

    /// 批量请求的限制(各家文档的上限,留有余量)和请求频率。
    var limits: BatchLimits {
        switch self {
        case .deepl: BatchLimits(maxItems: 50, maxLength: 30_000, maxConcurrent: 3, minInterval: 0)
        case .google: BatchLimits(maxItems: 100, maxLength: 5_000, maxConcurrent: 4, minInterval: 0)
        case .azure: BatchLimits(maxItems: 100, maxLength: 10_000, maxConcurrent: 3, minInterval: 0)
        case .volcengine: BatchLimits(maxItems: 8, maxLength: 5_000, maxConcurrent: 3, minInterval: 0.1)
        case .tencent: BatchLimits(maxItems: 50, maxLength: 5_000, maxConcurrent: 2, minInterval: 0.2)
        // 百度标准版 1 QPS;长度按 UTF-8 字节算(文档建议单次不超过 6000 字节),句间换行各占 1 字节。
        case .baidu: BatchLimits(maxItems: 50, maxLength: 6_000, countsUTF8Bytes: true, separatorLength: 1,
                                 maxConcurrent: 1, minInterval: 1.05)
        }
    }
}

/// 凭据字段。
nonisolated enum CredentialField: String, CaseIterable, Sendable {
    /// 主密钥 / ID(API Key、Access Key ID、SecretId、APP ID)。
    case key
    /// 第二个密钥(Secret Access Key、SecretKey、百度密钥)。
    case secret
    /// 区域(微软资源区域、腾讯云地域)。
    case region
}

/// 一家服务的凭据(值类型,可以安全地带到后台任务里)。
nonisolated struct MTCredentials: Equatable, Sendable {
    var key = ""
    var secret = ""
    var region = ""

    subscript(field: CredentialField) -> String {
        get {
            switch field {
            case .key: key
            case .secret: secret
            case .region: region
            }
        }
        set {
            switch field {
            case .key: key = newValue
            case .secret: secret = newValue
            case .region: region = newValue
            }
        }
    }

    /// 必填字段都已填写。
    func isComplete(for provider: TranslationProvider) -> Bool {
        provider.fields.allSatisfy { !provider.isRequired($0) || !self[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 去掉首尾空白(粘贴时常带空格或换行)。
    var trimmed: MTCredentials {
        MTCredentials(key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                      secret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                      region: region.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
