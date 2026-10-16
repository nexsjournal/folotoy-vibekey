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
nonisolated enum TargetLanguage: String, CaseIterable, Identifiable, Sendable {
    case en, zhHans = "zh-Hans", zhHant = "zh-Hant", ja, ko, fr, de, es, ru

    var id: String { rawValue }

    var title: String {
        switch self {
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

    /// 写进 LLM 提示词的语言名。
    var promptName: String {
        switch self {
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
    var subtitleFontSize: Double { didSet { defaults.set(subtitleFontSize, forKey: "subtitleFontSize") } }
    var subtitleLocked: Bool { didSet { defaults.set(subtitleLocked, forKey: "subtitleLocked") } }
    /// 结束字幕时询问是否保存字幕记录(提示框里勾选"不再询问"会关掉)。
    var askToSaveCaptions: Bool { didSet { defaults.set(askToSaveCaptions, forKey: "askToSaveCaptions") } }
    var llmBaseURL: String { didSet { defaults.set(llmBaseURL, forKey: "llmBaseURL") } }
    var llmModel: String { didSet { defaults.set(llmModel, forKey: "llmModel") } }
    var llmAPIKey: String { didSet { CredentialStore.shared.set(llmAPIKey, for: "llmAPIKey") } }
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
        translateTarget = TargetLanguage(rawValue: defaults.string(forKey: "translateTarget") ?? "") ?? .en
        subtitleTranslate = defaults.object(forKey: "subtitleTranslate") as? Bool ?? false
        subtitleTarget = TargetLanguage(rawValue: defaults.string(forKey: "subtitleTarget") ?? "") ?? .zhHans
        subtitleFontSize = defaults.object(forKey: "subtitleFontSize") as? Double ?? 22
        subtitleLocked = defaults.bool(forKey: "subtitleLocked")
        askToSaveCaptions = defaults.object(forKey: "askToSaveCaptions") as? Bool ?? true
        llmBaseURL = defaults.string(forKey: "llmBaseURL") ?? "https://api.openai.com/v1"
        llmModel = defaults.string(forKey: "llmModel") ?? ""
        CredentialStore.shared.migrateFromKeychain(account: "llmAPIKey")
        llmAPIKey = CredentialStore.shared.value(for: "llmAPIKey") ?? ""
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
