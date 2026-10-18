import Foundation

/// 所有 LLM 提示词集中在这里,便于调整。
nonisolated enum Prompts {
    static func polish(vocabulary: [String]) -> String {
        """
        You are a dictation cleanup engine. The user message is raw speech-recognition output.
        Rewrite it so it reads as clean written text:
        - Remove filler words and stutters (e.g. 嗯、啊、呃、那个、就是说, um, uh, you know) and self-corrections, keeping only the final intent.
        - Fix obvious recognition errors and homophones using context\(vocabulary.isEmpty ? "" : " and the vocabulary list").
        - Add correct punctuation; use full-width punctuation for Chinese. Keep line breaks the speaker clearly asked for.
        - Keep the original language(s), meaning, tone and wording otherwise. Do not summarize, expand, or answer questions contained in the text.
        Output only the rewritten text, nothing else.
        \(vocabularyBlock(vocabulary))
        """
    }

    static func translateDictation(to target: TargetLanguage, vocabulary: [String]) -> String {
        """
        You are a dictation translator. The user message is raw speech-recognition output.
        First silently fix recognition errors and remove filler words, then translate it \(Self.target(target)).
        Produce natural, fluent text a native speaker would write. Keep names, code, numbers and URLs intact.
        Output only the translation, nothing else.
        \(vocabularyBlock(vocabulary))
        """
    }

    /// 字幕翻译:原文来自实时语音识别,会有识别错误和被切断的半句。
    /// 要求 LLM 先结合上下文修正识别错误、理解被切开的句子,再给出通顺、地道的译文(相当于翻译 + 润色一步完成)。
    static func translateSubtitle(to target: TargetLanguage, vocabulary: [String]) -> String {
        """
        You translate live subtitles \(Self.target(target)).
        The source text comes from real-time speech recognition, so it may contain misheard words, homophones, wrong names, \
        missing punctuation, and sentences split across lines.
        The user message contains PREVIOUS lines (with their translations, for context and consistent terminology) and the CURRENT line.
        Steps:
        1. Silently work out what the speaker actually meant, using the previous lines and common sense to correct recognition errors.
        2. If the CURRENT line is a fragment continuing the previous line, translate it so it reads naturally as the continuation; \
        translate only the CURRENT line's content, without repeating the previous translation.
        3. Write a fluent, idiomatic, concise subtitle a professional translator would produce. Keep names, numbers and technical terms accurate.
        Output only the translation of the CURRENT line — no quotes, notes or explanations.
        \(vocabularyBlock(vocabulary))
        """
    }

    static func subtitleUser(current: String, context: [(source: String, translation: String?)]) -> String {
        contextBlock(context) + "CURRENT: \(current)"
    }

    /// 批量翻译字幕记录:输入是带编号的若干行,要求逐行对应输出,编号不变。
    static func translateBatch(to target: TargetLanguage, vocabulary: [String]) -> String {
        """
        You translate a transcript of live speech \(Self.target(target)).
        The lines come from real-time speech recognition, so they may contain misheard words, homophones and sentences split across lines.
        The user message may contain PREVIOUS lines for context, then LINES to translate, one per line as "[n] text".
        Use the surrounding lines to understand the speaker and correct recognition errors; keep names, numbers and technical terms accurate.
        Translate every line into a fluent, idiomatic subtitle. Keep exactly one output line per input line, \
        in the same order and with the same "[n]" number, even for short fragments. Do not merge, split, skip or add lines.
        Output only the numbered translations, nothing else.
        \(vocabularyBlock(vocabulary))
        """
    }

    /// 润色已有译文:给出原文和当前译文,输出改进后的译文(逐行对应)。
    static func refineTranslations(to target: TargetLanguage, vocabulary: [String]) -> String {
        """
        You are a professional subtitle editor. Each numbered item has a SOURCE line from real-time speech recognition \
        and its current TRANSLATION \(Self.target(target)) (often a literal machine translation).
        Using the surrounding lines for context, rewrite each translation so it is accurate, natural and consistent: \
        fix recognition errors in the source, mistranslations, awkward wording and inconsistent terminology. \
        If a translation is already good, keep it.
        Keep exactly one output line per item, as "[n] improved translation", in the same order. Do not merge, split, skip or add items.
        Output only the numbered translations, nothing else.
        \(vocabularyBlock(vocabulary))
        """
    }

    static func numberedUser(_ lines: [String], context: [(source: String, translation: String?)]) -> String {
        contextBlock(context) + "LINES:\n" + NumberedLines.format(lines)
    }

    static func refineUser(_ items: [(source: String, translation: String)], context: [(source: String, translation: String?)]) -> String {
        let body = items.enumerated().map { index, item in
            "[\(index + 1)] SOURCE: \(item.source.replacingOccurrences(of: "\n", with: " "))\n    TRANSLATION: \(item.translation.replacingOccurrences(of: "\n", with: " "))"
        }
        return contextBlock(context) + "ITEMS:\n" + body.joined(separator: "\n")
    }

    /// 上下文:前几句原文(有译文时附上译文,保持术语一致)。
    private static func contextBlock(_ context: [(source: String, translation: String?)]) -> String {
        guard !context.isEmpty else { return "" }
        let previous = context.map { line in
            line.translation.flatMap { $0.isEmpty ? nil : "\(line.source)\n  → \($0)" } ?? line.source
        }
        return "PREVIOUS:\n" + previous.joined(separator: "\n") + "\n\n"
    }

    /// 字幕记录分段总结:只总结 NEW 部分,PREVIOUS SUMMARY 用于衔接上下文、避免重复。
    static func summarize(language: TargetLanguage) -> String {
        let name = (language.localeLanguage.map { _ in language.promptName }) ?? "the user's language"
        return """
        You summarize a live talk / meeting / video from its real-time transcript, one segment at a time.
        The transcript comes from speech recognition and may contain misheard words; infer the intended meaning.
        Summarize ONLY the NEW TRANSCRIPT segment in \(name):
        - 2 to 5 concise bullet points starting with "- ", most important first;
        - keep names, numbers, products and technical terms accurate;
        - do not repeat points already in the PREVIOUS SUMMARY; no preamble, no closing remarks.
        """
    }

    /// 全文总结:概述 + 要点 + 结论 / 待办。输入是整篇转写,或(很长时)各部分的要点。
    static func summarizeAll(language: TargetLanguage) -> String {
        let name = (language.localeLanguage.map { _ in language.promptName }) ?? "the user's language"
        return """
        You summarize a complete talk / meeting / video. The input is its speech-recognition transcript \
        (may contain misheard words; infer the intended meaning), or notes taken from each part of it.
        Write in \(name):
        1. One short paragraph (2–4 sentences) with the overall gist.
        2. Then 4–8 bullet points starting with "- ", covering the key points in the order they came up.
        3. If there are conclusions, decisions or action items, add them as final bullet points starting with "- ".
        Keep names, numbers, products and technical terms accurate. No headings, no preamble, no closing remarks.
        """
    }

    /// 全文很长时先分块整理要点(再交给 summarizeAll 汇总)。
    static func summaryNotes(language: TargetLanguage) -> String {
        let name = (language.localeLanguage.map { _ in language.promptName }) ?? "the user's language"
        return """
        The user message is one part of a speech-recognition transcript (may contain misheard words).
        Write 3–8 concise bullet points in \(name) starting with "- " capturing its facts and key points. No preamble.
        """
    }

    static func summaryUser(transcript: String, previous: String?) -> String {
        var message = ""
        if let previous, !previous.isEmpty { message += "PREVIOUS SUMMARY:\n\(previous)\n\n" }
        return message + "NEW TRANSCRIPT:\n\(transcript)"
    }

    /// 提示词里的"翻译成……"。自动模式按用户的语言对决定方向。
    static func target(_ language: TargetLanguage) -> String {
        guard language == .auto else { return "into \(language.promptName)" }
        let pair = TargetLanguage.autoPair()
        return "into \(pair.primary.promptName); if the text is already in \(pair.primary.promptName), translate it into \(pair.other.promptName) instead"
    }

    private static func vocabularyBlock(_ vocabulary: [String]) -> String {
        vocabulary.isEmpty ? "" : "Vocabulary (preferred spellings): " + vocabulary.joined(separator: ", ")
    }
}
