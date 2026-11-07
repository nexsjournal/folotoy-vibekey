import Foundation

/// 翻译方式:每种场景一次只用一种。实时字幕(及字幕记录)用 `AppSettings.subtitleTranslationMethod`,
/// 听写翻译用 `AppSettings.dictationTranslationMethod`。
/// - `system`:macOS 自带的离线翻译(免费、几十毫秒);
/// - `provider`:在线机器翻译服务(Google / DeepL / 微软 / 火山引擎 / 腾讯云 / 百度);
/// - `llm`:AI 大模型(设置 › AI 服务 里配置的 OpenAI 兼容接口),`model` 为空表示跟随那里的默认模型。
nonisolated enum TranslationMethod: Hashable, Sendable, Identifiable {
    case system
    case provider(TranslationProvider)
    case llm(model: String)

    var id: String { storage }

    /// 存进 UserDefaults 的字符串:`system` / `mt.deepl` / `llm` / `llm:<model>`。
    var storage: String {
        switch self {
        case .system: "system"
        case .provider(let provider): "mt.\(provider.rawValue)"
        case .llm(let model): model.isEmpty ? "llm" : "llm:\(model)"
        }
    }

    init?(storage: String) {
        if storage == "system" {
            self = .system
        } else if storage == "llm" {
            self = .llm(model: "")
        } else if storage.hasPrefix("llm:") {
            self = .llm(model: String(storage.dropFirst(4)))
        } else if storage.hasPrefix("mt."), let provider = TranslationProvider(rawValue: String(storage.dropFirst(3))) {
            self = .provider(provider)
        } else {
            return nil
        }
    }

    var isLLM: Bool {
        if case .llm = self { return true }
        return false
    }

    /// 同一类(不区分 AI 选的哪个模型),界面上判断"选中的是哪一项"用。
    func sameKind(as other: TranslationMethod) -> Bool {
        switch (self, other) {
        case (.system, .system), (.llm, .llm): true
        case (.provider(let a), .provider(let b)): a == b
        default: false
        }
    }

    /// 完整名称(设置页、菜单)。AI 的模型名由调用方补上(需要知道"跟随设置"时的实际模型)。
    var title: String {
        switch self {
        case .system: String(localized: "系统翻译", bundle: .l10n)
        case .provider(let provider): provider.displayName
        case .llm: String(localized: "AI 大模型", bundle: .l10n)
        }
    }

    /// 一句话说明(设置页)。
    var detail: String {
        switch self {
        case .system: String(localized: "macOS 自带的离线翻译：免费、最快，不联网", bundle: .l10n)
        case .provider(let provider): provider.detail
        case .llm: String(localized: "结合上下文修正识别错误，译文最通顺；速度取决于模型", bundle: .l10n)
        }
    }
}
