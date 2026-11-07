import Foundation

/// 各服务商的目标语言代码(各家文档里的写法不统一,集中在这里对照)。
/// 只接受具体语言;`.auto` 要先按原文解析成具体语言(见 `TargetLanguage.resolvedTarget`)。
extension TranslationProvider {
    nonisolated func code(for target: TargetLanguage) -> String? {
        switch target {
        case .auto: return nil
        case .en:
            switch self {
            case .deepl: return "EN-US"
            default: return "en"
            }
        case .zhHans:
            switch self {
            case .deepl: return "ZH-HANS"
            case .google: return "zh-CN"
            case .azure: return "zh-Hans"
            case .volcengine, .tencent, .baidu: return "zh"
            }
        case .zhHant:
            switch self {
            case .deepl: return "ZH-HANT"
            case .google, .tencent: return "zh-TW"
            case .azure: return "zh-Hant"
            case .volcengine: return "zh-Hant"
            case .baidu: return "cht"
            }
        case .ja:
            switch self {
            case .deepl: return "JA"
            case .baidu: return "jp"
            default: return "ja"
            }
        case .ko:
            switch self {
            case .deepl: return "KO"
            case .baidu: return "kor"
            default: return "ko"
            }
        case .fr:
            switch self {
            case .deepl: return "FR"
            case .baidu: return "fra"
            default: return "fr"
            }
        case .de:
            switch self {
            case .deepl: return "DE"
            default: return "de"
            }
        case .es:
            switch self {
            case .deepl: return "ES"
            case .baidu: return "spa"
            default: return "es"
            }
        case .ru:
            switch self {
            case .deepl: return "RU"
            default: return "ru"
            }
        }
    }
}
