import Foundation
import Observation

/// 当前界面语言的资源包。所有 `String(localized: ..., bundle: .l10n)` 都从这里取,
/// 切换语言时只需替换这个包,不用重启 app。
nonisolated enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Bundle = resolveBundle(AppLanguage.saved)

    static var bundle: Bundle { lock.withLock { current } }

    static func use(_ language: AppLanguage) {
        let bundle = resolveBundle(language)
        lock.withLock { current = bundle }
    }

    /// 实际使用的语言代码(跟随系统时按系统首选语言在 app 支持的语言里挑)。
    static func code(for language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        case .system:
            return Bundle.preferredLocalizations(from: Bundle.main.localizations.filter { $0 != "Base" },
                                                 forPreferences: Locale.preferredLanguages).first ?? "zh-Hans"
        }
    }

    private static func resolveBundle(_ language: AppLanguage) -> Bundle {
        let code = code(for: language)
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

extension Bundle {
    /// 当前界面语言的资源包(见 `L10n`)。
    nonisolated static var l10n: Bundle { L10n.bundle }
}

/// 界面语言状态:SwiftUI 根视图读取 `locale` 并在变化时整体刷新。
@MainActor @Observable
final class LanguageState {
    private(set) var language = AppLanguage.saved
    private(set) var locale = Locale(identifier: L10n.code(for: AppLanguage.saved))

    /// 切换语言:保存偏好(下次启动也生效)、替换资源包、通知界面刷新。
    func set(_ language: AppLanguage) {
        AppLanguage.save(language)
        L10n.use(language)
        self.language = language
        locale = Locale(identifier: L10n.code(for: language))
    }
}
