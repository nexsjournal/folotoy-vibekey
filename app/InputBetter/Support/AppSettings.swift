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

/// 所有用户设置,改动即写入 UserDefaults;LLM 的 API Key 写入注入的 CredentialStore(本机凭据文件)。
@MainActor @Observable
final class AppSettings {
    static let passportMicID = "passport"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CredentialStore

    var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    var dictationModelID: String { didSet { defaults.set(dictationModelID, forKey: "dictationModelID") } }
    /// 空字符串表示跟随听写模型。
    var subtitleModelID: String { didSet { defaults.set(subtitleModelID, forKey: "subtitleModelID") } }
    var language: SpeechLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    /// 空字符串为系统默认输入设备,`passport` 为 Passport 麦克风,其余为 CoreAudio 设备 UID。
    var micID: String { didSet { defaults.set(micID, forKey: "micID") } }
    /// 听写后 AI 润色(去口水词、补标点、修正同音错字)。
    var polishEnabled: Bool { didSet { defaults.set(polishEnabled, forKey: "polishEnabled") } }
    /// 润色用的模型,空 = 用 AI 服务的默认模型(各功能可以各自选模型,接口和 Key 只在 AI 服务里配置一次)。
    var polishModel: String { didSet { defaults.set(polishModel, forKey: "polishModel") } }
    /// 听写翻译的目标语言。
    var translateTarget: TargetLanguage { didSet { defaults.set(translateTarget.rawValue, forKey: "translateTarget") } }
    /// 字幕默认翻译成的语言(点字幕条「译」就用它;在「译」旁的箭头里换语言也会改它)。翻译开关不在这里:
    /// 每场字幕默认不翻译,见 SubtitleController.translationEnabled。
    var subtitleTarget: TargetLanguage { didSet { defaults.set(subtitleTarget.rawValue, forKey: "subtitleTarget") } }
    /// 实时字幕的翻译方式(字幕条上切换也改这里;字幕记录窗口默认也用它)。
    var subtitleTranslationMethod: TranslationMethod { didSet { defaults.set(subtitleTranslationMethod.storage, forKey: "subtitleTranslationMethod") } }
    /// 听写翻译的翻译方式(和字幕分开:听写在意准确和顺带润色,字幕在意速度)。
    var dictationTranslationMethod: TranslationMethod { didSet { defaults.set(dictationTranslationMethod.storage, forKey: "dictationTranslationMethod") } }
    /// 边说边译:正在说的半句先给出暂定译文(系统翻译 / 在线服务;在线服务会多用一些额度)。
    var translationLiveDraft: Bool { didSet { defaults.set(translationLiveDraft, forKey: "translationLiveDraft") } }
    /// 字幕条原文字号(翻译与否都用它)。
    var subtitleSourceFontSize: Double { didSet { defaults.set(subtitleSourceFontSize, forKey: "subtitleSourceFontSize") } }
    /// 字幕条译文字号。
    var subtitleTranslationFontSize: Double { didSet { defaults.set(subtitleTranslationFontSize, forKey: "subtitleTranslationFontSize") } }
    /// 字号可调范围。
    static let subtitleFontRange: ClosedRange<Double> = 12...40
    /// 字幕条译文最多显示几行(2–5):行数多,一句译文停留得久,读得完。
    var subtitleTranslationLines: Int { didSet { defaults.set(subtitleTranslationLines, forKey: "subtitleTranslationLines") } }
    /// 翻译时原文最多显示几行(0 = 不显示,只看译文;1–3)。不翻译时原文固定 2 行大字。
    var subtitleSourceLines: Int { didSet { defaults.set(subtitleSourceLines, forKey: "subtitleSourceLines") } }
    var subtitleLocked: Bool { didSet { defaults.set(subtitleLocked, forKey: "subtitleLocked") } }
    /// 结束字幕前确认(提示框里勾选"不再询问"会关掉)。
    var confirmStopCaptions: Bool { didSet { defaults.set(confirmStopCaptions, forKey: "confirmStopCaptions") } }
    var llmBaseURL: String { didSet { defaults.set(llmBaseURL, forKey: "llmBaseURL") } }
    var llmModel: String { didSet { defaults.set(llmModel, forKey: "llmModel") } }
    var llmAPIKey: String { didSet { credentials.set(llmAPIKey, for: "llmAPIKey") } }
    /// 字幕记录"总结":间隔(分钟)、模型(开关不在这里:每场新的字幕默认关闭,见 TranscriptSummarizer.enabled)。
    /// 接口只能用设置里配置的 LLM 服务(不单独填写地址和 Key);模型可以从该服务的模型列表里另选,空 = 跟随 AI 设置。
    var summaryInterval: Int { didSet { defaults.set(summaryInterval, forKey: "summaryInterval") } }
    var summaryModel: String { didSet { defaults.set(summaryModel, forKey: "summaryModel") } }

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

    /// - Parameters:
    ///   - defaults: 普通设置的存储(测试里传独立的 suite);
    ///   - credentials: API Key 的存储(app 里由 AppState 创建并与其他配置共用同一个实例)。
    init(defaults: UserDefaults = .standard, credentials: CredentialStore = .shared) {
        self.defaults = defaults
        self.credentials = credentials
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        dictationModelID = defaults.string(forKey: "dictationModelID") ?? ModelCatalog.defaultModelID
        subtitleModelID = defaults.string(forKey: "subtitleModelID") ?? ""
        language = SpeechLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        micID = defaults.string(forKey: "micID") ?? ""
        polishEnabled = defaults.object(forKey: "polishEnabled") as? Bool ?? false
        polishModel = defaults.string(forKey: "polishModel") ?? ""
        translateTarget = TargetLanguage(rawValue: defaults.string(forKey: "translateTarget") ?? "") ?? .auto
        subtitleTarget = TargetLanguage(rawValue: defaults.string(forKey: "subtitleTarget") ?? "") ?? .auto
        let legacyMethod = Self.legacyTranslationMethod(defaults)
        let subtitleMethod = defaults.string(forKey: "subtitleTranslationMethod").flatMap(TranslationMethod.init(storage:)) ?? legacyMethod
        let dictationMethod = defaults.string(forKey: "dictationTranslationMethod").flatMap(TranslationMethod.init(storage:)) ?? legacyMethod
        // 迁移来的初始值要立即保存(init 里赋值不触发 didSet),否则旧键删掉后下次启动就丢了。
        defaults.set(subtitleMethod.storage, forKey: "subtitleTranslationMethod")
        defaults.set(dictationMethod.storage, forKey: "dictationTranslationMethod")
        subtitleTranslationMethod = subtitleMethod
        dictationTranslationMethod = dictationMethod
        translationLiveDraft = defaults.object(forKey: "translationLiveDraft") as? Bool ?? true
        // 旧版本只有一个"字号":不翻译时是原文字号,翻译时原文 / 译文按它的 64% / 68% 缩放。按比例换算成两个字号后删掉旧键。
        let legacyFontSize = defaults.object(forKey: "subtitleFontSize") as? Double
        defaults.removeObject(forKey: "subtitleFontSize")
        let sourceFont = defaults.object(forKey: "subtitleSourceFontSize") as? Double ?? (legacyFontSize.map { ($0 * 0.75).rounded() } ?? 17)
        let translationFont = defaults.object(forKey: "subtitleTranslationFontSize") as? Double ?? (legacyFontSize.map { ($0 * 0.85).rounded() } ?? 19)
        defaults.set(sourceFont, forKey: "subtitleSourceFontSize")
        defaults.set(translationFont, forKey: "subtitleTranslationFontSize")
        subtitleSourceFontSize = sourceFont
        subtitleTranslationFontSize = translationFont
        subtitleTranslationLines = min(max(defaults.object(forKey: "subtitleTranslationLines") as? Int ?? 3, 2), 5)
        subtitleSourceLines = min(max(defaults.object(forKey: "subtitleSourceLines") as? Int ?? 2, 0), 3)
        subtitleLocked = defaults.bool(forKey: "subtitleLocked")
        confirmStopCaptions = defaults.object(forKey: "confirmStopCaptions") as? Bool ?? true
        // 旧版本结束时询问保存 / 总结全文,现在只确认是否结束。
        ["askToSaveCaptions", "summarizeOnEnd"].forEach(defaults.removeObject)
        llmBaseURL = defaults.string(forKey: "llmBaseURL") ?? "https://api.openai.com/v1"
        llmModel = defaults.string(forKey: "llmModel") ?? ""
        Self.runOnce("migratedLLMKeyFromKeychain", defaults) { credentials.migrateFromKeychain(account: "llmAPIKey") }
        llmAPIKey = credentials.value(for: "llmAPIKey") ?? ""
        defaults.removeObject(forKey: "summaryEnabled")  // 旧版本把开关存成全局设置;现在每场字幕默认关闭
        summaryInterval = defaults.object(forKey: "summaryInterval") as? Int ?? 2
        summaryModel = defaults.string(forKey: "summaryModel") ?? ""
        // 旧版本允许总结单独填写接口和 Key,现在只用设置里的服务:清掉遗留的配置。
        if defaults.object(forKey: "summaryUsesCustomLLM") != nil {
            ["summaryUsesCustomLLM", "summaryBaseURL"].forEach(defaults.removeObject)
            defaults.removeObject(forKey: "summaryModel")
            summaryModel = ""
        }
        Self.runOnce("removedSummaryAPIKey", defaults) { credentials.set(nil, for: "summaryAPIKey") }
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

    /// 旧版本的翻译方式(字幕和听写还没分开时),用作两个新设置的初始值,读取后删除旧键:
    /// - 共用的 `translationMethod`(上一个测试版);
    /// - 更早的「翻译方式」`translationEngine`:混合模式已去掉 → 系统翻译,仅 AI → AI(跟随设置里的模型);
    /// - 旧的全局翻译开关 `subtitleTranslate` 不再使用(每场字幕默认不翻译)。
    private static func legacyTranslationMethod(_ defaults: UserDefaults) -> TranslationMethod {
        defer { ["translationMethod", "translationEngine", "subtitleTranslate"].forEach(defaults.removeObject) }
        if let stored = defaults.string(forKey: "translationMethod"), let method = TranslationMethod(storage: stored) { return method }
        return defaults.string(forKey: "translationEngine") == "llm" ? .llm(model: "") : .system
    }

    /// 一次性迁移:做过就在 UserDefaults 里记一笔,之后启动不再执行(避免每次启动都访问钥匙串、重写凭据文件)。
    private static func runOnce(_ key: String, _ defaults: UserDefaults, _ work: () -> Void) {
        let flag = "migration.\(key)"
        guard !defaults.bool(forKey: flag) else { return }
        work()
        defaults.set(true, forKey: flag)
    }

    var effectiveSubtitleModelID: String { subtitleModelID.isEmpty ? dictationModelID : subtitleModelID }

    /// 总结使用的 LLM:设置里的服务(接口和 Key),模型用总结选的(没选则跟随 AI 设置);没配置好返回 nil。
    var summaryLLMConfig: LLMClient.Config? {
        guard llmConfigured else { return nil }
        return .init(baseURL: llmBaseURL, apiKey: llmAPIKey, model: summaryModel.isEmpty ? llmModel : summaryModel)
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
