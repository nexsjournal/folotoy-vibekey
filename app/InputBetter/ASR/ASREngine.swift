import Foundation

/// 识别事件:`partial` 是尚未定稿的尾部(会被替换),`final` 是新定稿的一段。
nonisolated enum TranscriptEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
    /// 识别出错(如云端鉴权失败、网络中断),附带可读的原因。
    case failure(String)
}

nonisolated enum ASRPurpose: Sendable {
    /// 听写:松开后整段重识别,追求准确。
    case dictation
    /// 字幕:连续运行,短句尽快定稿。
    case subtitles
}

nonisolated struct ASROptions: Sendable {
    var purpose: ASRPurpose
    var language: SpeechLanguage
    var vocabulary: [String]
}

/// 一次识别会话。`feed` 可在任意线程调用(16 kHz 单声道)。
nonisolated protocol ASRSession: AnyObject, Sendable {
    var events: AsyncStream<TranscriptEvent> { get }
    func feed(_ samples: [Float])
    /// 结束输入,返回完整定稿文本。
    func finish() async -> String
    func cancel()
    /// 暂停 / 恢复解码(输入照常缓存)。用于听写期间让出识别算力;流式引擎可以忽略。
    func setDecodingPaused(_ paused: Bool)
}

nonisolated extension ASRSession {
    func setDecodingPaused(_ paused: Bool) {}
}

@MainActor
protocol ASREngine: AnyObject {
    var isLoaded: Bool { get }
    /// 加载模型(耗时操作,可重复调用)。
    func prepare() async throws
    func makeSession(_ options: ASROptions) async throws -> ASRSession
    func unload()
}

nonisolated enum TranscriptText {
    /// 拼接两段识别结果:中日韩文字之间不加空格,拉丁文字之间加空格。
    static func join(_ parts: [String]) -> String {
        var result = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = result.unicodeScalars.last, let first = part.unicodeScalars.first,
               !isCJK(last), !isCJK(first), !CharacterSet.whitespaces.contains(last) {
                result += " "
            }
            result += part
        }
        return result
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// 清理识别结果:
    /// - 去掉中日韩文字或全角标点两侧多余的空格(Apple Speech 常见);
    /// - 紧跟在中文后面的半角标点换成全角(Whisper 常输出半角逗号句号)。
    static func normalize(_ s: String) -> String {
        let fullWidth: [Unicode.Scalar: Unicode.Scalar] = [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"]
        var out = String.UnicodeScalarView()
        let scalars = Array(s.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        for (i, c) in scalars.enumerated() {
            let prev = out.last
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if c == " " {
                if let prev, isCJK(prev) { continue }
                if let next, isCJK(next) { continue }
            }
            // 半角标点前是中文、后面不是数字(避免 3.14 这类)时转全角。
            if let full = fullWidth[c], let prev, isCJK(prev), !(next.map { CharacterSet.decimalDigits.contains($0) } ?? false) {
                out.append(full)
                continue
            }
            out.append(c)
        }
        return String(out)
    }

    /// Whisper 偶尔输出繁体,中文场景下统一转成简体。
    static func toSimplified(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
    }

    /// 去掉 Whisper 在静音片段上常见的幻听内容。
    static func isHallucination(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if t.isEmpty { return true }
        let patterns = ["字幕由", "请不吝点赞", "订阅", "Amara.org", "Thank you for watching", "谢谢观看", "明镜与点点"]
        return t.count < 30 && patterns.contains { t.localizedCaseInsensitiveContains($0) }
    }
}
