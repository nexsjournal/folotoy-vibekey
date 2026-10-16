import AppKit

/// 翻译的唯一入口(字幕和听写共用),按设置的翻译方式组合系统翻译和 LLM:
///
/// 字幕一句:`translateLine`
///   系统翻译(几百毫秒)→ `.draft` 先显示 → LLM 结合上下文和初稿润色 → 完整生成后 `.final` 一次性替换
///   (有初稿时不逐字替换,避免闪烁);没有初稿时 LLM 逐字流式 `.streaming`。
///   只有系统翻译 → 初稿即定稿;都不可用 → `.failed`。
/// 字幕条上刚说完的句子:`quickTranslate`(只用系统翻译,够快才能跟上)。
/// 听写翻译:`translateDictation`(有 LLM 用 LLM,顺带去口水词;否则用系统翻译)。
///
/// 系统翻译需要源语言:用 LanguageDetector 识别,识别不出时沿用上一次识别到的语言。
@MainActor @Observable
final class TranslationService {
    /// 一句字幕翻译的进展。
    enum LineUpdate: Equatable {
        /// 系统翻译初稿(之后可能被 LLM 结果替换)。
        case draft(String)
        /// LLM 逐字生成中(没有初稿时)。
        case streaming(String)
        /// 最终译文。
        case final(String)
        /// 原文已经是目标语言,不需要翻译。
        case sameLanguage
        case failed(String)
    }

    /// 当前目标语言对应的系统翻译语言包是否已下载(界面判断"能不能翻译"用)。
    private(set) var systemReady = false
    /// 系统翻译语言包状态(给设置页显示)。
    private(set) var systemStatus: SystemStatus = .checking

    enum SystemStatus: Equatable {
        case checking, installed, needsDownload, unsupported
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let processor: TextProcessor
    @ObservationIgnored private let system = SystemTranslator()
    /// 最近一次识别到的源语言(短句识别不出时沿用)。
    @ObservationIgnored private var lastSource: Locale.Language?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    init(settings: AppSettings, processor: TextProcessor) {
        self.settings = settings
        self.processor = processor
        observeChanges({ [weak self] in _ = (self?.settings.subtitleTarget, self?.settings.translateTarget) }) { [weak self] in
            Task { await self?.refreshSystemStatus() }
        }
        // 用户可能在"系统设置 › 通用 › 语言与地区 › 翻译语言"里下载或删除了语言包。
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.system.invalidate()
                Task { await self?.refreshSystemStatus() }
            }
        }
    }

    /// 按当前翻译方式,字幕翻译是否可用。
    var isAvailable: Bool {
        let engine = settings.translationEngine
        return (engine.usesSystem && systemReady) || (engine.usesLLM && processor.isAvailable)
    }

    /// 听写翻译是否可用。
    var canTranslateDictation: Bool { isAvailable }

    /// 需要下载时用的语言对(设置页"下载"按钮交给系统的 `.translationTask`)。
    var downloadPair: (source: Locale.Language, target: Locale.Language) {
        let pair = Self.probePair(for: settings.subtitleTarget)
        return (pair.source, pair.target)
    }

    // MARK: - 字幕

    func translateLine(_ text: String, context: [(source: String, translation: String?)]) -> AsyncStream<LineUpdate> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                await self.runLine(text, context: context, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runLine(_ text: String, context: [(source: String, translation: String?)],
                         _ continuation: AsyncStream<LineUpdate>.Continuation) async {
        let engine = settings.translationEngine
        let source = detectSource(text)
        let target = settings.subtitleTarget.resolved(source: source)
        if let source, LanguageDetector.same(source, target), settings.subtitleTarget != .auto {
            continuation.yield(.sameLanguage)
            return
        }

        var draft: String?
        var lastError: String?
        if engine.usesSystem, let source {
            do {
                draft = try await system.translate(text, from: source, to: target)
                if let draft { continuation.yield(.draft(draft)) }
            } catch {
                lastError = error.localizedDescription
            }
        }
        guard !Task.isCancelled else { return }

        if engine.usesLLM, processor.isAvailable {
            do {
                var latest = ""
                for try await partial in try processor.translateSubtitle(text, context: context, draft: draft) {
                    latest = partial
                    if draft == nil { continuation.yield(.streaming(partial)) }
                }
                continuation.yield(.final(latest))
                return
            } catch {
                lastError = error.localizedDescription
                Log.llm.error("subtitle LLM translation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let draft {
            continuation.yield(.final(draft))
        } else {
            continuation.yield(.failed(lastError ?? String(localized: "翻译不可用", bundle: .l10n)))
        }
    }

    /// 快速翻译(字幕条上刚说完的句子):只用系统翻译(LLM 太慢跟不上);不可用时返回 nil。
    func quickTranslate(_ text: String) async -> String? {
        guard settings.translationEngine.usesSystem, systemReady else { return nil }
        guard let source = detectSource(text) ?? lastSource else { return nil }
        let target = settings.subtitleTarget.resolved(source: source)
        if LanguageDetector.same(source, target) { return nil }
        return try? await system.translate(text, from: source, to: target)
    }

    // MARK: - 听写

    /// 听写翻译:LLM 可用且方式允许时用 LLM(会顺带修正识别错误、去口水词),否则用系统翻译。
    func translateDictation(_ text: String) async throws -> String {
        let engine = settings.translationEngine
        if engine.usesLLM, processor.isAvailable {
            return try await processor.translate(text)
        }
        guard engine.usesSystem, let source = LanguageDetector.detect(text) else { throw LLMError.notConfigured }
        let target = settings.translateTarget.resolved(source: source)
        return try await system.translate(text, from: source, to: target)
    }

    // MARK: - 系统翻译语言包

    /// 重新检查当前目标语言对的语言包状态。
    func refreshSystemStatus() async {
        let pair = Self.probePair(for: settings.subtitleTarget)
        let status = await system.status(from: pair.source, to: pair.target)
        switch status {
        case .installed: systemStatus = .installed
        case .supported: systemStatus = .needsDownload
        default: systemStatus = .unsupported
        }
        systemReady = systemStatus == .installed
    }

    /// 语言包下载完成后调用。
    func systemDownloadFinished() async {
        system.invalidate()
        await refreshSystemStatus()
    }

    /// 检查语言包时用的语言对:自动模式取"另一种语言 → 主语言"(字幕最常见的方向);
    /// 固定目标时假设原文是主语言(目标就是主语言时假设原文是另一种语言)。
    nonisolated static func probePair(for target: TargetLanguage, preferred: [String] = Locale.preferredLanguages) -> (source: Locale.Language, target: Locale.Language) {
        let pair = TargetLanguage.autoPair(preferred: preferred)
        let primary = pair.primary.localeLanguage ?? Locale.Language(identifier: "en")
        let other = pair.other.localeLanguage ?? Locale.Language(identifier: "en")
        guard let fixed = target.localeLanguage else { return (other, primary) }
        return (LanguageDetector.same(fixed, primary) ? other : primary, fixed)
    }

    // MARK: - 内部

    /// 识别源语言;识别出来就记住,识别不出时沿用上一次的。
    private func detectSource(_ text: String) -> Locale.Language? {
        if let detected = LanguageDetector.detect(text) {
            lastSource = detected
            return detected
        }
        return lastSource
    }
}
