import AppKit

/// 翻译的唯一入口(字幕、字幕记录、听写共用)。按调用方给的翻译方式(TranslationMethod)分派,一次只用一种:
/// - 系统翻译:SystemTranslator(本机,需要源语言,用 LanguageDetector 识别);
/// - 在线机器翻译:MachineTranslator(服务端自动识别源语言);
/// - AI:TextProcessor(带上下文,逐字流式)。
///
/// 对外的能力:
/// - `translateLine`:字幕一句(AI 逐字 `.streaming`,最后 `.final`);
/// - `translateBatch`:多句一起(字幕实时翻译的句子、字幕记录窗口);按 BatchPlanner 分组切块,经 RequestGate 限流;
/// - `draft`:正在说、还没说完的半句的暂定译文(只用系统翻译 / 在线服务,够快才有意义);
/// - `translateDictation`:听写翻译。
/// 原文已是目标语言的句子不发请求,结果为 ""(界面不显示译文);服务原样返回的也记为 ""。
@MainActor @Observable
final class TranslationService {
    /// 一句字幕翻译的进展。
    enum LineUpdate: Equatable {
        /// AI 逐字生成中(到目前为止的译文)。
        case streaming(String)
        /// 最终译文。
        case final(String)
        /// 原文已经是目标语言,不需要翻译。
        case sameLanguage
        case failed(String)
    }

    /// 系统翻译语言包状态,按目标语言(字幕和听写的目标语言各查一次:语言对不同,需要的语言包也不同)。
    private(set) var systemStatuses: [TargetLanguage: SystemStatus] = [:]

    func systemStatus(for target: TargetLanguage) -> SystemStatus { systemStatuses[target] ?? .checking }
    /// 字幕目标语言的语言包状态(引导页等只关心字幕的地方用)。
    var systemStatus: SystemStatus { systemStatus(for: settings.subtitleTarget) }
    var systemReady: Bool { systemStatus == .installed }

    enum SystemStatus: Equatable {
        case checking, installed, needsDownload, unsupported
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let processor: TextProcessor
    @ObservationIgnored let providers: MachineTranslationStore
    @ObservationIgnored private let system = SystemTranslator()
    /// 每家在线服务一个闸门(字幕和字幕记录共用),AI 一个。
    @ObservationIgnored private var gates: [String: RequestGate] = [:]
    /// 最近一次识别到的源语言(短句识别不出时沿用)。
    @ObservationIgnored private var lastSource: Locale.Language?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    init(settings: AppSettings, processor: TextProcessor, providers: MachineTranslationStore) {
        self.settings = settings
        self.processor = processor
        self.providers = providers
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

    // MARK: - 可用性

    /// 这种翻译方式现在能不能用(系统翻译按 `target` 的语言包判断,默认字幕的目标语言)。
    func isAvailable(_ method: TranslationMethod, target: TargetLanguage? = nil) -> Bool {
        unavailableReason(method, target: target) == nil
    }

    /// 字幕的翻译方式能不能用(Passport 上键)。
    var isAvailable: Bool { isAvailable(settings.subtitleTranslationMethod) }

    /// 听写的翻译方式能不能用(按听写的目标语言)。
    var canTranslateDictation: Bool { isAvailable(settings.dictationTranslationMethod, target: settings.translateTarget) }

    /// 不能用的原因(界面提示);能用时为 nil。
    func unavailableReason(_ method: TranslationMethod, target: TargetLanguage? = nil) -> String? {
        switch method {
        case .system:
            switch systemStatus(for: target ?? settings.subtitleTarget) {
            // 还没查过(启动后一瞬间,或「自动」解析出的具体语言还没单独查):不拦,翻译前 ensureSystemStatus 会按实际
            // 语言对先查一次;真的没下载时 SystemTranslator 也会给出具体错误。不能把「正在检查」当成失败原因显示给用户。
            case .installed, .checking: return nil
            case .needsDownload: return String(localized: "系统翻译的语言包还没下载", bundle: .l10n)
            case .unsupported: return String(localized: "系统翻译不支持这个语言", bundle: .l10n)
            }
        case .provider(let provider):
            return providers.isConfigured(provider) ? nil : String(localized: "\(provider.displayName) 还没有配置密钥", bundle: .l10n)
        case .llm:
            return processor.isAvailable ? nil : String(localized: "还没有配置 AI 服务", bundle: .l10n)
        }
    }

    /// AI 实际使用的模型(`.llm("")` 跟随设置)。
    func modelName(_ method: TranslationMethod) -> String? {
        guard case .llm(let model) = method else { return nil }
        return model.isEmpty ? settings.llmModel : model
    }

    /// 这种方式的批量限制。
    func limits(for method: TranslationMethod) -> BatchLimits {
        switch method {
        case .system: .system
        case .provider(let provider): provider.limits
        case .llm: .llm
        }
    }

    /// 需要下载时用的语言对(设置页"下载"按钮交给系统的 `.translationTask`)。
    func downloadPair(for target: TargetLanguage) -> (source: Locale.Language, target: Locale.Language) {
        let pair = Self.probePair(for: target)
        return (pair.source, pair.target)
    }

    // MARK: - 字幕一句

    /// 翻译一句字幕。AI:逐字 `.streaming`,最后 `.final`;其他方式:一次 `.final`。
    func translateLine(_ text: String, context: [(source: String, translation: String?)],
                       target: TargetLanguage, method: TranslationMethod) -> AsyncStream<LineUpdate> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                await self.runLine(text, context: context, target: target, method: method, continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runLine(_ text: String, context: [(source: String, translation: String?)], target: TargetLanguage,
                         method: TranslationMethod, _ continuation: AsyncStream<LineUpdate>.Continuation) async {
        guard case .llm(let model) = method else {
            do {
                let id = UUID()
                let result = try await translateBatch([BatchPlanner.Item(id: id, text: text)], target: target, method: method)
                let translation = result[id] ?? ""
                continuation.yield(translation.isEmpty ? .sameLanguage : .final(translation))
            } catch is CancellationError {
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
            return
        }
        if isSameLanguage(text, target: target) {
            continuation.yield(.sameLanguage)
            return
        }
        if let reason = unavailableReason(method, target: target) {
            continuation.yield(.failed(reason))
            return
        }
        do {
            // 和批量 / 润色一样经 AI 的闸门(并发 2):一次定稿切出的几句不会同时开出多路流式请求。
            let processor = processor
            let latest: String = try await gate(for: method).run { @MainActor in
                var latest = ""
                let stream = try processor.translateSubtitle(text, context: context, to: target, model: model)
                for try await partial in stream {
                    latest = partial
                    continuation.yield(.streaming(partial))
                }
                return latest
            }
            continuation.yield(.final(latest))
        } catch is CancellationError {
        } catch {
            Log.llm.error("subtitle LLM translation failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    // MARK: - 批量

    /// 翻译多句。返回每句的译文("" = 原文已是目标语言)。
    /// 各块依次执行(字幕实时翻译一次只有几句;字幕记录窗口的批量翻译自己按块并发,见 TranscriptTranslator);
    /// 在线服务限流 / 临时故障时重试一次。
    /// 某一块失败:密钥 / 额度这类错误直接抛出(整批都不会成功),其他错误也抛出(由调用方决定标记失败)。
    func translateBatch(_ items: [BatchPlanner.Item], target: TargetLanguage, method: TranslationMethod,
                        context: [ContextLine] = []) async throws -> [UUID: String] {
        await ensureSystemStatus(for: target, method: method)
        if let reason = unavailableReason(method, target: target) { throw TranslationError.unavailable(reason) }
        let plan = plan(items, target: target, method: method)
        var results: [UUID: String] = [:]
        plan.skipped.forEach { results[$0] = "" }
        for chunk in plan.chunks {
            let translations = try await translateChunk(chunk, method: method, context: context)
            for (item, translation) in zip(chunk.items, translations) { results[item.id] = translation }
        }
        return results
    }

    /// 系统翻译的语言包状态还没查过(启动后、刚换目标语言)时先查一次,避免把「正在检查」当成不可用。
    private func ensureSystemStatus(for target: TargetLanguage, method: TranslationMethod) async {
        guard method == .system, systemStatus(for: target) == .checking else { return }
        await refreshSystemStatus(for: target)
    }

    /// 把要翻译的句子分块(见 BatchPlanner);源语言识别不出时沿用上一句的语言。
    func plan(_ items: [BatchPlanner.Item], target: TargetLanguage, method: TranslationMethod) -> BatchPlanner.Plan {
        BatchPlanner.plan(items, target: target, limits: limits(for: method), groupBySource: method == .system,
                          detect: { [unowned self] in detectSource($0) })
    }

    /// AI 润色已有译文(字幕记录窗口)。`model` 为空 = 跟随设置。经 AI 的闸门限流。
    func refine(_ items: [ContextLine], context: [ContextLine], target: TargetLanguage, model: String) async throws -> [String] {
        guard processor.isAvailable else { throw TranslationError.unavailable(String(localized: "还没有配置 AI 服务", bundle: .l10n)) }
        let processor = processor
        return try await gate(for: .llm(model: model)).run { @MainActor in
            try await processor.refineTranslations(items.map { (source: $0.source, translation: $0.translation ?? "") },
                                                   context: ContextLine.tuples(context), to: target, model: model)
        }
    }

    /// 翻译一块(同一语言对)。字幕记录窗口直接按块调用,以便显示进度、控制并发。
    /// 返回值与 `chunk.items` 一一对应;服务原样返回(原文就是目标语言,本机没识别出来)时记为 ""(不需要译文),
    /// 目标是简体中文时统一转简体 —— 这两条归一化只在这里做一次,所有调用方直接用结果。
    func translateChunk(_ chunk: BatchPlanner.Chunk, method: TranslationMethod,
                        context: [ContextLine] = []) async throws -> [String] {
        // chunk.target 是解析后的具体语言(「自动」→ 简体中文等),它的语言包状态可能还没查过:先查再判断。
        await ensureSystemStatus(for: chunk.target, method: method)
        if let reason = unavailableReason(method, target: chunk.target) { throw TranslationError.unavailable(reason) }
        let raw = try await rawChunk(chunk, method: method, context: context)
        return zip(chunk.items, raw).map { item, translation in
            translation == item.text ? "" : Self.normalized(translation, target: chunk.target)
        }
    }

    private func rawChunk(_ chunk: BatchPlanner.Chunk, method: TranslationMethod, context: [ContextLine]) async throws -> [String] {
        // 各家在线服务都按"一句一条"返回,句内换行会被当成分隔(百度)或原样带回:统一换成空格。
        let texts = chunk.items.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        switch method {
        case .system:
            guard let source = chunk.source ?? lastSource, let target = chunk.target.localeLanguage else {
                throw TranslationError.unavailable(String(localized: "无法识别原文的语言", bundle: .l10n))
            }
            var results: [String] = []
            for text in texts {
                try Task.checkCancellation()
                results.append(try await system.translate(text, from: source, to: target))
            }
            return results
        case .provider(let provider):
            let translator = try MachineTranslatorFactory.make(provider, credentials: providers.credentials(provider))
            let target = chunk.target
            return try await withRetry(gate(for: method)) { try await translator.translate(texts, to: target) }
        case .llm(let model):
            let target = chunk.target
            let processor = processor
            return try await gate(for: method).run { @MainActor in
                do {
                    return try await processor.translateBatch(texts, context: ContextLine.tuples(context), to: target, model: model)
                } catch LLMError.empty where texts.count > 1 {
                    // 模型没按编号逐行输出:改为逐句翻译。
                    var results: [String] = []
                    for text in texts { results.append(try await processor.translate(text, to: target, model: model)) }
                    return results
                }
            }
        }
    }

    // MARK: - 半句暂定译文

    /// 正在说的半句的暂定译文(边说边译)。只用系统翻译 / 在线服务;不可用、同语言或失败时返回 nil(不打扰字幕)。
    func draft(_ text: String, target: TargetLanguage, method: TranslationMethod) async -> String? {
        guard !method.isLLM else { return nil }
        await ensureSystemStatus(for: target, method: method)
        guard isAvailable(method, target: target) else { return nil }
        let id = UUID()
        guard let result = try? await translateBatch([BatchPlanner.Item(id: id, text: text)], target: target, method: method),
              let translation = result[id], !translation.isEmpty else { return nil }
        return translation
    }

    // MARK: - 听写

    /// 听写翻译,用听写的翻译方式和目标语言。AI 会顺带修正识别错误、去口水词。
    func translateDictation(_ text: String) async throws -> String {
        let method = settings.dictationTranslationMethod
        let target = settings.translateTarget
        if case .llm(let model) = method {
            return try await processor.translate(text, to: target, model: model)
        }
        let id = UUID()
        let result = try await translateBatch([BatchPlanner.Item(id: id, text: text)], target: target, method: method)
        let translation = result[id] ?? ""
        return translation.isEmpty ? text : translation
    }

    // MARK: - 系统翻译语言包

    /// 重新检查字幕和听写目标语言对的语言包状态。
    func refreshSystemStatus() async {
        for target in Set([settings.subtitleTarget, settings.translateTarget]) {
            await refreshSystemStatus(for: target)
        }
    }

    private func refreshSystemStatus(for target: TargetLanguage) async {
        let pair = Self.probePair(for: target)
        let status: SystemStatus = switch await system.status(from: pair.source, to: pair.target) {
        case .installed: .installed
        case .supported: .needsDownload
        default: .unsupported
        }
        systemStatuses[target] = status
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

    /// 目标是简体中文时统一转成简体(系统翻译偶尔会混出繁体字,实测"修飾符""屬性")。
    nonisolated static func normalized(_ translation: String, target: TargetLanguage) -> String {
        target == .zhHans ? TranscriptText.toSimplified(translation) : translation
    }

    /// 识别源语言;识别出来就记住,识别不出时沿用上一次的。
    private func detectSource(_ text: String) -> Locale.Language? {
        if let detected = LanguageDetector.detect(text) {
            lastSource = detected
            return detected
        }
        return lastSource
    }

    private func isSameLanguage(_ text: String, target: TargetLanguage) -> Bool {
        guard let source = detectSource(text), let resolved = target.resolvedTarget(source: source).localeLanguage else { return false }
        return LanguageDetector.same(source, resolved)
    }

    private func gate(for method: TranslationMethod) -> RequestGate {
        let key = method.isLLM ? "llm" : method.storage
        if let gate = gates[key] { return gate }
        let gate = RequestGate(limits: limits(for: method))
        gates[key] = gate
        return gate
    }

    /// 经闸门执行;限流 / 临时故障时重试一次:限流按服务端给的 Retry-After 等待(最多 10 秒),没给则 1 秒。
    private func withRetry<T: Sendable>(_ gate: RequestGate, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await gate.run(operation)
        } catch let error as MachineTranslationError where error.isRetryable {
            var wait: TimeInterval = 1
            if case .rateLimited(_, let retryAfter) = error, let retryAfter { wait = min(max(retryAfter, 1), 10) }
            try await Task.sleep(for: .seconds(wait))
            return try await gate.run(operation)
        }
    }

    enum TranslationError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            }
        }
    }
}
