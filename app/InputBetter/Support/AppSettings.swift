import Foundation

/// 识别语言。`auto` 交给引擎自动检测(Apple Speech 不支持自动检测,用系统首选语言)。
nonisolated enum SpeechLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto, zh, en, ja, ko, yue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: String(localized: "自动检测", bundle: .l10n)
        case .zh: String(localized: "中文", bundle: .l10n)
        case .en: "English"
        case .ja: String(localized: "日本語", bundle: .l10n)
        case .ko: "한국어"
        case .yue: String(localized: "粤语", bundle: .l10n)
        }
    }

    /// Apple Speech 使用的区域;`auto` 取系统首选语言。
    var appleLocale: Locale {
        switch self {
        case .zh: Locale(identifier: "zh-CN")
        case .en: Locale(identifier: "en-US")
        case .ja: Locale(identifier: "ja-JP")
        case .ko: Locale(identifier: "ko-KR")
        case .yue: Locale(identifier: "yue-CN")
        // Apple Speech 不能自动检测语言:系统语言里有中文就用中文,否则用第一首选语言。
        case .auto:
            Locale.preferredLanguages.contains(where: { $0.hasPrefix("zh") })
                ? Locale(identifier: "zh-CN")
                : Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
        }
    }

    /// Whisper / SenseVoice 的语言代码,nil 表示自动检测。
    var isoCode: String? { self == .auto ? nil : rawValue }
}

/// 翻译目标语言(听写翻译与字幕翻译共用)。
/// `auto`(默认)由 LLM 按内容决定方向:说 / 听到的是用户的主语言就译成另一种语言,否则译成主语言
/// (例如中文用户:中文 → English,其他语言 → 简体中文)。语言对见 `autoPair`。
nonisolated enum TargetLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto, en, zhHans = "zh-Hans", zhHant = "zh-Hant", ja, ko, fr, de, es, ru

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: String(localized: "自动", bundle: .l10n)
        case .en: "English"
        case .zhHans: String(localized: "简体中文", bundle: .l10n)
        case .zhHant: String(localized: "繁體中文", bundle: .l10n)
        case .ja: String(localized: "日本語", bundle: .l10n)
        case .ko: "한국어"
        case .fr: "Français"
        case .de: "Deutsch"
        case .es: "Español"
        case .ru: "Русский"
        }
    }

    /// 写进 LLM 提示词的语言名(auto 不是具体语言,提示词用 `Prompts.target` 展开)。
    var promptName: String {
        switch self {
        case .auto: "the appropriate language"
        case .en: "English"
        case .zhHans: "Simplified Chinese"
        case .zhHant: "Traditional Chinese"
        case .ja: "Japanese"
        case .ko: "Korean"
        case .fr: "French"
        case .de: "German"
        case .es: "Spanish"
        case .ru: "Russian"
        }
    }

    /// 自动模式的语言对:用户的主语言(系统首选语言)和另一种语言
    /// (英语;主语言就是英语时取第二首选语言,没有则用简体中文)。
    static func autoPair(preferred: [String] = Locale.preferredLanguages) -> (primary: TargetLanguage, other: TargetLanguage) {
        let languages = preferred.compactMap(TargetLanguage.init(localeIdentifier:))
        let primary = languages.first ?? .en
        let other = primary == .en ? (languages.first { $0 != .en } ?? .zhHans) : .en
        return (primary, other)
    }

    /// 自动模式的说明,如"简体中文 → English，其他语言 → 简体中文"。
    static var autoSummary: String {
        let pair = autoPair()
        return String(localized: "\(pair.primary.title) → \(pair.other.title)，其他语言 → \(pair.primary.title)", bundle: .l10n)
    }

    /// 从系统语言标识(如 zh-Hans-CN、zh-TW、en-US)对应到支持的目标语言。
    init?(localeIdentifier: String) {
        let language = Locale.Language(identifier: localeIdentifier)
        switch language.languageCode?.identifier {
        case "en": self = .en
        case "zh":
            let traditional = language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(language.region?.identifier ?? "")
            self = traditional ? .zhHant : .zhHans
        case "ja": self = .ja
        case "ko": self = .ko
        case "fr": self = .fr
        case "de": self = .de
        case "es": self = .es
        case "ru": self = .ru
        default: return nil
        }
    }
}

/// 翻译方式(字幕和听写翻译共用)。
nonisolated enum TranslationEngine: String, CaseIterable, Identifiable, Sendable {
    /// 系统翻译先出(离线、几百毫秒),配置了 AI 时再用 AI 结合上下文润色替换。
    case hybrid
    /// 只用系统翻译(免费、离线、不需要 AI)。
    case system
    /// 只用 AI(需要配置 LLM)。
    case llm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hybrid: String(localized: "系统翻译 + AI 润色", bundle: .l10n)
        case .system: String(localized: "仅系统翻译", bundle: .l10n)
        case .llm: String(localized: "仅 AI", bundle: .l10n)
        }
    }

    var detail: String {
        switch self {
        case .hybrid: String(localized: "系统翻译立即给出译文，配置了 AI 时再结合上下文修正识别错误、润色替换", bundle: .l10n)
        case .system: String(localized: "macOS 自带的离线翻译，免费、速度快，不需要 AI", bundle: .l10n)
        case .llm: String(localized: "全部交给 AI，质量最好但要等 AI 生成", bundle: .l10n)
        }
    }

    var usesSystem: Bool { self != .llm }
    var usesLLM: Bool { self != .system }
}

/// 所有用户设置,改动即写入 UserDefaults。
@MainActor @Observable
final class AppSettings {
    static let passportMicID = "passport"

    @ObservationIgnored private let defaults: UserDefaults

    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    var dictationModelID: String { didSet { defaults.set(dictationModelID, forKey: "dictationModelID") } }
    /// 空字符串表示跟随听写模型。
    var subtitleModelID: String { didSet { defaults.set(subtitleModelID, forKey: "subtitleModelID") } }
    var language: SpeechLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    /// 空字符串为系统默认输入设备,`passport` 为 Passport 麦克风,其余为 CoreAudio 设备 UID。
    var micID: String { didSet { defaults.set(micID, forKey: "micID") } }
    var polishEnabled: Bool { didSet { defaults.set(polishEnabled, forKey: "polishEnabled") } }
    var translateTarget: TargetLanguage { didSet { defaults.set(translateTarget.rawValue, forKey: "translateTarget") } }
    var subtitleTranslate: Bool { didSet { defaults.set(subtitleTranslate, forKey: "subtitleTranslate") } }
    var subtitleTarget: TargetLanguage { didSet { defaults.set(subtitleTarget.rawValue, forKey: "subtitleTarget") } }
    var translationEngine: TranslationEngine { didSet { defaults.set(translationEngine.rawValue, forKey: "translationEngine") } }
    var subtitleFontSize: Double { didSet { defaults.set(subtitleFontSize, forKey: "subtitleFontSize") } }
    var subtitleLocked: Bool { didSet { defaults.set(subtitleLocked, forKey: "subtitleLocked") } }
    /// 结束字幕时询问是否保存字幕记录(提示框里勾选"不再询问"会关掉)。
    var askToSaveCaptions: Bool { didSet { defaults.set(askToSaveCaptions, forKey: "askToSaveCaptions") } }
    var llmBaseURL: String { didSet { defaults.set(llmBaseURL, forKey: "llmBaseURL") } }
    var llmModel: String { didSet { defaults.set(llmModel, forKey: "llmModel") } }
    var llmAPIKey: String { didSet { CredentialStore.shared.set(llmAPIKey, for: "llmAPIKey") } }
    /// 字幕记录"总结":开关、间隔(分钟)、是否单独指定接口。
    var summaryEnabled: Bool { didSet { defaults.set(summaryEnabled, forKey: "summaryEnabled") } }
    var summaryInterval: Int { didSet { defaults.set(summaryInterval, forKey: "summaryInterval") } }
    var summaryUsesCustomLLM: Bool { didSet { defaults.set(summaryUsesCustomLLM, forKey: "summaryUsesCustomLLM") } }
    var summaryBaseURL: String { didSet { defaults.set(summaryBaseURL, forKey: "summaryBaseURL") } }
    var summaryModel: String { didSet { defaults.set(summaryModel, forKey: "summaryModel") } }
    var summaryAPIKey: String { didSet { CredentialStore.shared.set(summaryAPIKey, for: "summaryAPIKey") } }
    var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    var useMirror: Bool { didSet { defaults.set(useMirror, forKey: "useMirror") } }
    var soundEffects: Bool { didSet { defaults.set(soundEffects, forKey: "soundEffects") } }
    var deviceBluetooth: Bool { didSet { defaults.set(deviceBluetooth, forKey: "deviceBluetooth") } }
    var deviceScreenOff: Int { didSet { defaults.set(deviceScreenOff, forKey: "deviceScreenOff") } }
    var showPill: Bool { didSet { defaults.set(showPill, forKey: "showPill") } }
    /// Passport 按键映射(vibe coding 默认:上 = 回车,下 = Esc,长按下 = 切换应用;长按上固定为切换模式)。
    var deviceUpAction: KeyAction { didSet { defaults.set(deviceUpAction.rawValue, forKey: "deviceUpAction") } }
    var deviceDownAction: KeyAction { didSet { defaults.set(deviceDownAction.rawValue, forKey: "deviceDownAction") } }
    var deviceDownLongAction: KeyAction { didSet { defaults.set(deviceDownLongAction.rawValue, forKey: "deviceDownLongAction") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        dictationModelID = defaults.string(forKey: "dictationModelID") ?? ModelCatalog.defaultModelID
        subtitleModelID = defaults.string(forKey: "subtitleModelID") ?? ""
        language = SpeechLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        micID = defaults.string(forKey: "micID") ?? ""
        polishEnabled = defaults.object(forKey: "polishEnabled") as? Bool ?? false
        translateTarget = TargetLanguage(rawValue: defaults.string(forKey: "translateTarget") ?? "") ?? .auto
        subtitleTranslate = defaults.object(forKey: "subtitleTranslate") as? Bool ?? false
        subtitleTarget = TargetLanguage(rawValue: defaults.string(forKey: "subtitleTarget") ?? "") ?? .auto
        translationEngine = TranslationEngine(rawValue: defaults.string(forKey: "translationEngine") ?? "") ?? .hybrid
        subtitleFontSize = defaults.object(forKey: "subtitleFontSize") as? Double ?? 22
        subtitleLocked = defaults.bool(forKey: "subtitleLocked")
        askToSaveCaptions = defaults.object(forKey: "askToSaveCaptions") as? Bool ?? true
        llmBaseURL = defaults.string(forKey: "llmBaseURL") ?? "https://api.openai.com/v1"
        llmModel = defaults.string(forKey: "llmModel") ?? ""
        CredentialStore.shared.migrateFromKeychain(account: "llmAPIKey")
        llmAPIKey = CredentialStore.shared.value(for: "llmAPIKey") ?? ""
        summaryEnabled = defaults.bool(forKey: "summaryEnabled")
        summaryInterval = defaults.object(forKey: "summaryInterval") as? Int ?? 2
        summaryUsesCustomLLM = defaults.bool(forKey: "summaryUsesCustomLLM")
        summaryBaseURL = defaults.string(forKey: "summaryBaseURL") ?? "https://api.openai.com/v1"
        summaryModel = defaults.string(forKey: "summaryModel") ?? ""
        summaryAPIKey = CredentialStore.shared.value(for: "summaryAPIKey") ?? ""
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        useMirror = defaults.bool(forKey: "useMirror")
        soundEffects = defaults.object(forKey: "soundEffects") as? Bool ?? true
        deviceBluetooth = defaults.object(forKey: "deviceBluetooth") as? Bool ?? true
        deviceScreenOff = defaults.object(forKey: "deviceScreenOff") as? Int ?? 60
        showPill = defaults.object(forKey: "showPill") as? Bool ?? true
        deviceUpAction = KeyAction(rawValue: defaults.string(forKey: "deviceUpAction") ?? "") ?? .enter
        deviceDownAction = KeyAction(rawValue: defaults.string(forKey: "deviceDownAction") ?? "") ?? .escape
        deviceDownLongAction = KeyAction(rawValue: defaults.string(forKey: "deviceDownLongAction") ?? "") ?? .appSwitcher
    }

    var effectiveSubtitleModelID: String { subtitleModelID.isEmpty ? dictationModelID : subtitleModelID }

    /// 总结使用的 LLM:单独指定时用总结自己的接口,否则用 AI 设置里的服务;没配置好返回 nil。
    var summaryLLMConfig: LLMClient.Config? {
        if summaryUsesCustomLLM {
            guard OpenAICompatibleAPI.endpoint(summaryBaseURL, "chat/completions") != nil, !summaryModel.isEmpty else { return nil }
            return .init(baseURL: summaryBaseURL, apiKey: summaryAPIKey, model: summaryModel)
        }
        guard llmConfigured else { return nil }
        return .init(baseURL: llmBaseURL, apiKey: llmAPIKey, model: llmModel)
    }

    var llmConfigured: Bool {
        !llmBaseURL.trimmingCharacters(in: .whitespaces).isEmpty && !llmModel.isEmpty
    }

    /// 词汇表:每行一个词,去掉空行。
    var vocabularyTerms: [String] {
        vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
