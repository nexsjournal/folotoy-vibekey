import Foundation

/// 字幕条显示的"滚动字幕"(roll-up captions,电视直播字幕、Apple 实时字幕、YouTube 自动字幕的通行做法):
/// 不按句分块,把最近几句定稿和正在说的半句连成一段连续的文字;界面用固定 2 行的框底部对齐显示,
/// 新词接在末尾,写满后最旧的一行整行滚出顶部——最新的内容永远在右下角,也不用省略号截断。
/// 原文和译文各是一段(译文按句子顺序拼接,正在说的半句用系统翻译的实时译文)。
/// `final` 是定稿部分,`live` 是还会变的部分(界面上略暗)。纯数据,便于测试。
nonisolated struct RollingCaption: Equatable, Sendable {
    var sourceFinal = ""
    var sourceLive = ""
    var translationFinal = ""
    var translationLive = ""

    /// 每段最多保留的字符数(远多于两行能显示的量,只是避免拼接过长的字符串)。
    static let maxCharacters = 280
    /// 取最近几句参与拼接。
    static let recentEntries = 8

    var hasSource: Bool { !sourceFinal.isEmpty || !sourceLive.isEmpty }
    var hasTranslation: Bool { !translationFinal.isEmpty || !translationLive.isEmpty }

    static func make(entries: [CaptionTranscript.Entry], partial: String, partialTranslation: String?) -> RollingCaption {
        let recent = entries.suffix(recentEntries)
        let source = split(final: recent.map(\.text), live: partial)
        let translations = recent.compactMap { entry -> String? in
            guard let translation = entry.translation, !translation.isEmpty else { return nil }
            return translation
        }
        let translation = split(final: translations, live: partial.isEmpty ? "" : partialTranslation ?? "")
        return RollingCaption(sourceFinal: source.final, sourceLive: source.live,
                              translationFinal: translation.final, translationLive: translation.live)
    }

    /// 拼接(按 TranscriptText.join 处理中英文之间的空格),再从前面裁掉超出的部分。
    /// 返回的 live 带着与前文之间的分隔空格,界面直接把两段接起来即可。
    static func split(final parts: [String], live: String) -> (final: String, live: String) {
        let finalText = TranscriptText.join(parts)
        let full = TranscriptText.join(parts + [live])
        var liveText = String(full.dropFirst(finalText.count))
        var finalPart = finalText
        let overflow = full.count - maxCharacters
        if overflow > 0 {
            if overflow >= finalPart.count {
                liveText = String(liveText.suffix(maxCharacters))
                finalPart = ""
            } else {
                finalPart = trimFront(finalPart, by: overflow)
            }
        }
        return (finalPart, liveText)
    }

    /// 从前面去掉至少 `count` 个字符;拉丁文字在空格处断开,避免留下半个单词。
    private static func trimFront(_ text: String, by count: Int) -> String {
        let cut = text.dropFirst(count)
        if let first = cut.first, !first.isWhitespace, let last = text.dropLast(cut.count).last, !last.isWhitespace,
           first.isLetter, first.unicodeScalars.allSatisfy({ !TranscriptText.isCJK($0) }),
           let space = cut.firstIndex(where: \.isWhitespace) {
            return String(cut[space...]).trimmingCharacters(in: .whitespaces)
        }
        return String(cut).trimmingCharacters(in: .whitespaces)
    }
}
