import Foundation

/// Whisper 的自动语言检测在两点上不可靠：
/// - 1–2 秒的短句样本太少，容易把中文判成英文；
/// - 中文里夹英文单词时，英文概率会明显抬高。
///
/// 这里不取消自动检测，而是在结果上做一层“主语言偏置”：
/// 置信度不足、或主语言概率接近时用主语言解码。Whisper 用中文 token 解码时，
/// 夹在句子里的英文单词仍会正常输出英文，不需要为每个词切语言。
nonisolated enum SpeechLanguageDetection {
    /// 用户系统首选语言，作为自动检测的偏置。中文系统返回 `zh`。
    static func preferredLanguage(_ preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard let first = preferredLanguages.first else { return "zh" }
        let code = first.split(separator: "-").first.map(String.init)?.lowercased() ?? "zh"
        return code.isEmpty ? "zh" : code
    }

    /// - Parameters:
    ///   - detected: Whisper 返回的最高概率语言。
    ///   - probabilities: Whisper 的 `langProbs`。
    ///   - preferred: 主语言（中文系统为 `zh`）。
    ///   - sampleCount: 16 kHz 采样点数。
    static func resolve(detected: String, probabilities: [String: Float],
                        preferred: String, sampleCount: Int) -> String {
        let detected = normalize(detected)
        let preferred = normalize(preferred)
        let minimumForDetection = 16_000 * 2

        // 2 秒以内不足以稳定判断语种；直接按主语言解码。
        guard sampleCount >= minimumForDetection else { return preferred }
        // 自动检测失败 / 返回空值时也不要退回英文。
        guard !detected.isEmpty else { return preferred }
        if detected == preferred { return preferred }

        let top = probabilities[detected] ?? 0
        let primary = probabilities[preferred] ?? 0

        // 主语言概率不低，且第一名没有压倒性优势：按主语言解码（中文夹英文的典型情况）。
        if primary >= 0.30, top < 0.80 { return preferred }
        // 检测结果本身不够自信：用主语言。
        if top < 0.40 { return preferred }
        return detected
    }

    private static func normalize(_ code: String) -> String {
        let value = code.lowercased()
        if value.hasPrefix("zh") { return "zh" }
        if value.hasPrefix("yue") { return "yue" }
        return value
    }
}
