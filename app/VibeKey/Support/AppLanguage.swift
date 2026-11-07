import Foundation

/// 界面语言:跟随系统 / 简体中文 / English。
/// 选择保存在本 app 的 AppleLanguages 偏好里(与 系统设置 › 通用 › 语言与地区 › 应用程序 是同一个值),
/// 运行中切换由 `LanguageState` / `L10n` 即时生效,不需要重启。
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    /// 语言名用各自的语言书写,方便用户在看不懂当前界面时也能找到。
    var title: String {
        switch self {
        case .system: String(localized: "跟随系统", bundle: .l10n)
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }

    private static let key = "AppleLanguages"

    /// 当前保存的选择(只看本 app 自己的偏好,不看全局)。
    static var saved: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String],
              let first = list.first else { return .system }
        if first.hasPrefix("zh") { return .zhHans }
        if first.hasPrefix("en") { return .en }
        return .system
    }

    static func save(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }
}
