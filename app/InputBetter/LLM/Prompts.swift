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
        if context.isEmpty { return "CURRENT: \(current)" }
        let previous = context.map { line in
            line.translation.map { "\(line.source)\n  → \($0)" } ?? line.source
        }
        return "PREVIOUS:\n" + previous.joined(separator: "\n") + "\n\nCURRENT: \(current)"
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
