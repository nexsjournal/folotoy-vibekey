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
        First silently fix recognition errors and remove filler words, then translate it into \(target.promptName).
        Produce natural, fluent text a native speaker would write. Keep names, code, numbers and URLs intact.
        Output only the translation, nothing else.
        \(vocabularyBlock(vocabulary))
        """
    }

    static func translateSubtitle(to target: TargetLanguage) -> String {
        """
        You translate live subtitles into \(target.promptName).
        The user message contains optional previous lines for context and the CURRENT line.
        Translate only the CURRENT line, concisely and naturally, as a subtitle. If it is already in \(target.promptName), output it unchanged.
        Output only the translation of the current line.
        """
    }

    static func subtitleUser(current: String, context: [String]) -> String {
        if context.isEmpty { return "CURRENT: \(current)" }
        return "PREVIOUS:\n" + context.joined(separator: "\n") + "\n\nCURRENT: \(current)"
    }

    private static func vocabularyBlock(_ vocabulary: [String]) -> String {
        vocabulary.isEmpty ? "" : "Vocabulary (preferred spellings): " + vocabulary.joined(separator: ", ")
    }
}
