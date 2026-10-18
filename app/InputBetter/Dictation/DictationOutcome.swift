import Foundation

/// 听写流程中各状态的类型化描述。界面通过 `title` 显示(已本地化),
/// 其他模块(如 Passport 状态映射、胶囊颜色)按类型判断,不比较文案。

/// 处理中的步骤。
nonisolated enum ProcessingStep: Equatable, Sendable {
    case loadingModel, recognizing, polishing, translating

    var title: String {
        switch self {
        case .loadingModel: String(localized: "加载模型", bundle: .l10n)
        case .recognizing: String(localized: "识别中", bundle: .l10n)
        case .polishing: String(localized: "润色中", bundle: .l10n)
        case .translating: String(localized: "翻译中", bundle: .l10n)
        }
    }
}

/// 没能直接粘贴、只复制到剪贴板的原因。
nonisolated enum CopyReason: Equatable, Sendable {
    case noAccessibility, secureInput, windowChanged

    var title: String {
        switch self {
        case .noAccessibility: String(localized: "未获得辅助功能权限，已复制", bundle: .l10n)
        case .secureInput: String(localized: "安全输入中，已复制", bundle: .l10n)
        case .windowChanged: String(localized: "窗口已切换，已复制", bundle: .l10n)
        }
    }
}

/// 后处理(润色 / 翻译)失败、退回原文时的警告。附带的字符串是失败原因(错误描述)。
nonisolated enum PostProcessWarning: Equatable, Sendable {
    case untranslated(String)
    case unpolished(String)
}

/// 后处理的结果:要输入的文字,以及退回原文时的警告(nil = 正常完成或不需要后处理)。
nonisolated struct PostProcessed: Equatable, Sendable {
    let text: String
    let warning: PostProcessWarning?
}

/// 完成结果。
nonisolated enum DictationResult: Equatable, Sendable {
    case typed
    /// 翻译失败,已输入原文;附带失败原因。
    case typedUntranslated(String)
    /// 润色失败,已输入原文;附带失败原因。
    case typedUnpolished(String)
    case copied(CopyReason)

    /// 已粘贴后,按后处理警告得到最终结果。
    static func typed(warning: PostProcessWarning?) -> DictationResult {
        switch warning {
        case nil: .typed
        case .untranslated(let reason): .typedUntranslated(reason)
        case .unpolished(let reason): .typedUnpolished(reason)
        }
    }

    var title: String {
        switch self {
        case .typed: String(localized: "已输入", bundle: .l10n)
        case .typedUntranslated(let reason): String(localized: "翻译失败，已输入原文：\(reason)", bundle: .l10n)
        case .typedUnpolished(let reason): String(localized: "润色失败，已输入原文：\(reason)", bundle: .l10n)
        case .copied(let reason): reason.title
        }
    }

    /// 是否需要用警告色显示(文字输入了,但不是用户要的结果)。
    var isWarning: Bool {
        switch self {
        case .typedUntranslated, .typedUnpolished: true
        case .typed, .copied: false
        }
    }
}

/// 失败原因。
nonisolated enum DictationFailure: Equatable, Sendable {
    case noModel, engineNotReady, noSpeech
    /// 听写翻译的方式现在不能用;附带原因(来自 `TranslationService.unavailableReason`)。
    case translationUnavailable(reason: String)
    /// 系统或引擎返回的错误描述。
    case other(String)

    var title: String {
        switch self {
        case .noModel: String(localized: "识别模型不可用，请在设置里下载或配置", bundle: .l10n)
        case .translationUnavailable(let reason): String(localized: "无法翻译：\(reason)", bundle: .l10n)
        case .engineNotReady: String(localized: "识别引擎未就绪", bundle: .l10n)
        case .noSpeech: String(localized: "没有听到声音", bundle: .l10n)
        case .other(let message): message
        }
    }
}
