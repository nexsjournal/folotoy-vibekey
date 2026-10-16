import Foundation

/// 听写流程中各状态的类型化描述。界面通过 `title` 显示(已本地化),
/// 其他模块(如 Passport 状态映射)按类型判断,不比较文案。

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

/// 完成结果。
nonisolated enum DictationResult: Equatable, Sendable {
    case typed
    case copied(CopyReason)

    var title: String {
        switch self {
        case .typed: String(localized: "已输入", bundle: .l10n)
        case .copied(let reason): reason.title
        }
    }
}

/// 失败原因。
nonisolated enum DictationFailure: Equatable, Sendable {
    case noModel, translationUnavailable, engineNotReady, noSpeech
    /// 系统或引擎返回的错误描述。
    case other(String)

    var title: String {
        switch self {
        case .noModel: String(localized: "识别模型不可用，请在设置里下载或配置", bundle: .l10n)
        case .translationUnavailable: String(localized: "翻译需要下载系统翻译语言或配置 AI", bundle: .l10n)
        case .engineNotReady: String(localized: "识别引擎未就绪", bundle: .l10n)
        case .noSpeech: String(localized: "没有听到声音", bundle: .l10n)
        case .other(let message): message
        }
    }
}
