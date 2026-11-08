import Foundation

/// 听写的后处理:翻译模式按听写的翻译方式和目标语言翻译,听写模式按设置做 AI 润色。
/// 只决定"做什么、失败怎么办",具体能力交给 TranslationService / TextProcessor。
/// 调用链:DictationController.stop → DictationPostProcessor.process → TranslationService.translateDictation | TextProcessor.polish。
@MainActor
final class DictationPostProcessor: DictationPostProcessing {
    private let settings: AppSettings
    private let processor: TextProcessor
    private let translation: TranslationService

    init(settings: AppSettings, processor: TextProcessor, translation: TranslationService) {
        self.settings = settings
        self.processor = processor
        self.translation = translation
    }

    var translationUnavailableReason: String? {
        translation.unavailableReason(settings.dictationTranslationMethod, target: settings.translateTarget)
    }

    func step(for mode: DictationController.Mode) -> ProcessingStep? {
        switch mode {
        case .translate: .translating
        case .dictate where settings.polishEnabled && processor.isAvailable: .polishing
        case .dictate: nil
        }
    }

    func process(_ text: String, mode: DictationController.Mode) async -> PostProcessed {
        // 先用词汇表做确定性纠错（DeepSeek / DIPSEEK），再决定要不要走大模型。
        let corrected = VocabularyCorrector.apply(text, entries: settings.vocabularyEntries)
        guard let step = step(for: mode) else { return PostProcessed(text: corrected, warning: nil) }
        do {
            let result = step == .translating
                ? try await translation.translateDictation(corrected)
                : try await processor.polish(corrected)
            return PostProcessed(text: result, warning: nil)
        } catch {
            // 被取消(用户点了 ✕)不算失败,调用方会放弃这次输入。
            if error is CancellationError || Task.isCancelled { return PostProcessed(text: corrected, warning: nil) }
            // 失败时退回原文,不丢用户说的话;同时告诉用户这不是译文 / 润色后的结果。
            Log.llm.error("post-process failed: \(error.localizedDescription, privacy: .public)")
            let reason = error.localizedDescription
            return PostProcessed(text: corrected, warning: step == .translating ? .untranslated(reason) : .unpolished(reason))
        }
    }
}
