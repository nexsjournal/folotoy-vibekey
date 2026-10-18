import Foundation
import NaturalLanguage

/// 识别一段文字的语言(NaturalLanguage 框架,本机离线)。
/// 系统翻译必须指定源语言,所以翻译前先识别;太短或不确定时返回 nil,由调用方沿用上一句的语言。
nonisolated enum LanguageDetector {
    /// 置信度低于这个值视为不确定。
    static let minimumConfidence = 0.5

    static func detect(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// 是否同一种语言(中文还要区分简体 / 繁体)。
    static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard let codeA = a.languageCode, codeA == b.languageCode else { return false }
        guard codeA.identifier == "zh" else { return true }
        return script(a) == script(b)
    }

    /// 文字体系;没写时按最可能的补全(zh → Hans)。
    private static func script(_ language: Locale.Language) -> String? {
        language.script?.identifier ?? Locale.Language(identifier: language.maximalIdentifier).script?.identifier
    }
}

extension TargetLanguage {
    /// 对应的系统语言(auto 没有固定语言,返回 nil)。
    nonisolated var localeLanguage: Locale.Language? {
        self == .auto ? nil : Locale.Language(identifier: rawValue)
    }

    /// 确定实际的目标语言:固定语言直接用;自动模式下原文是主语言就译成另一种语言,否则译成主语言
    /// (与 `Prompts.target` 给 LLM 的规则一致)。
    nonisolated func resolved(source: Locale.Language?, preferred: [String] = Locale.preferredLanguages) -> Locale.Language {
        resolvedTarget(source: source, preferred: preferred).localeLanguage ?? Locale.Language(identifier: "en")
    }

    /// 同 `resolved`,返回具体的 TargetLanguage(不会是 .auto),在线服务按它查语言代码。
    nonisolated func resolvedTarget(source: Locale.Language?, preferred: [String] = Locale.preferredLanguages) -> TargetLanguage {
        guard self == .auto else { return self }
        let pair = TargetLanguage.autoPair(preferred: preferred)
        if let source, let primary = pair.primary.localeLanguage, LanguageDetector.same(source, primary) { return pair.other }
        return pair.primary
    }
}
