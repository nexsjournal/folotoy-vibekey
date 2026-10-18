import Foundation

/// 字幕记录窗口里的翻译:字幕进行中或结束后,把记录里的句子单独翻译 / 重新翻译 / 用 AI 润色译文。
///
/// 调用链:TranscriptTranslationBar(按钮)→ translateMissing / retranslateAll / polish
///   → TranslationService.plan(按语言对分块)→ 每块 TranslationService.translateChunk / refine(经闸门限流,
///   与字幕实时翻译共用频率限制)→ 结果每 0.3 秒批量写回 SubtitleController.applyTranslations → 记录窗口刷新。
/// - 不会自动开始:在窗口的语言菜单里选了语言才翻译(和字幕条一致);换方式只改变下次用哪种方式;
/// - 进行中可以取消,已经写回的结果保留;密钥 / 额度等错误停止整批并提示,其他错误只标记那几句失败;
/// - 语言和方式默认跟随字幕条(设置),在窗口里改过后只对这场字幕的窗口有效;新的一场字幕开始时复位。
@MainActor @Observable
final class TranscriptTranslator {
    enum Kind: Equatable { case translate, polish }

    /// 进行中的任务进度。
    struct Job: Equatable {
        /// 任务标识:取消后立刻再开一个新任务时,旧任务体不能再写新任务的状态 / 错误。
        let id = UUID()
        let kind: Kind
        let method: TranslationMethod
        var total: Int
        var done = 0
    }

    private(set) var job: Job?
    /// 最近一次任务的错误(下一次开始时清除)。
    private(set) var error: String?
    /// 出错的是哪种任务(润色出错要去配置 AI 服务,翻译出错去配置当前翻译方式)。
    private(set) var errorKind: Kind?
    /// 记录窗口里是否显示译文(拷贝和保存也按这个决定是否带上译文)。
    var showTranslations = true

    /// 窗口里选的目标语言(nil = 跟随字幕条)。
    var targetOverride: TargetLanguage?
    /// 窗口里选的翻译方式(nil = 跟随设置)。
    var methodOverride: TranslationMethod?

    var target: TargetLanguage { targetOverride ?? settings.subtitleTarget }
    var method: TranslationMethod { methodOverride ?? settings.subtitleTranslationMethod }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let subtitles: SubtitleController
    @ObservationIgnored private let translation: TranslationService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sessionID: UUID?

    /// AI 润色一次处理的句数。
    private static let polishChunk = 12
    /// 字幕实时翻译还在处理的新句子不重复翻译(秒)。
    private static let liveGrace: TimeInterval = 10

    init(settings: AppSettings, subtitles: SubtitleController, translation: TranslationService) {
        self.settings = settings
        self.subtitles = subtitles
        self.translation = translation
    }

    // MARK: - 状态

    /// 需要翻译的句子:还没有译文、翻译失败,或译文是别的语言。
    var pendingEntries: [CaptionTranscript.Entry] {
        let now = Date(), live = subtitles.translationEnabled && subtitles.isRunning
        return subtitles.transcript.entries.filter { entry in
            if entry.translation == nil {
                // 实时翻译还在路上的新句子交给它(按定稿时间算:句子定稿后实时翻译才开始翻它)。
                return entry.translationFailed || !(live && now.timeIntervalSince(entry.finalizedAt) < Self.liveGrace)
            }
            return entry.translationTarget != nil && entry.translationTarget != target
        }
    }

    /// 可以 AI 润色的句子:已有本语言的译文、还没润色过。
    var polishableEntries: [CaptionTranscript.Entry] {
        subtitles.transcript.entries.filter {
            !($0.translation ?? "").isEmpty && !$0.translationPolished && ($0.translationTarget ?? target) == target
        }
    }

    var transcriptIsEmpty: Bool { subtitles.transcript.isEmpty }
    var hasTranslations: Bool { subtitles.transcript.entries.contains { !($0.translation ?? "").isEmpty } }
    var canPolish: Bool { settings.llmConfigured }
    var unavailableReason: String? { translation.unavailableReason(method) }

    // MARK: - 操作

    func translateMissing() {
        resetIfNewSession()
        run(.translate, entries: pendingEntries)
    }

    func retranslateAll() {
        resetIfNewSession()
        run(.translate, entries: subtitles.transcript.entries)
    }

    func polish() {
        resetIfNewSession()
        run(.polish, entries: polishableEntries)
    }

    func cancel() {
        task?.cancel()
        task = nil
        job = nil
    }

    /// 新的一场字幕开始后,窗口里的选择和进行中的任务复位(TranscriptView 出现和会话变化时调用)。
    func resetIfNewSession() {
        let id = subtitles.transcript.id
        guard sessionID != id else { return }
        sessionID = id
        cancel()
        error = nil
        targetOverride = nil
        methodOverride = nil
        showTranslations = true
    }

    // MARK: - 执行

    private func run(_ kind: Kind, entries: [CaptionTranscript.Entry]) {
        guard job == nil, !entries.isEmpty else { return }
        error = nil
        errorKind = kind
        let method = method, target = target
        // 方式现在用不了(服务被移除、语言包被删、状态还没查完):直接说明原因,不开跑后逐块失败。
        if kind == .translate, let reason = translation.unavailableReason(method, target: target) {
            error = reason
            return
        }
        if kind == .polish, !canPolish {
            error = String(localized: "还没有配置 AI 服务", bundle: .l10n)
            return
        }
        showTranslations = true
        let session = subtitles.transcript.id
        let newJob = Job(kind: kind, method: method, total: entries.count)
        job = newJob
        task = Task {
            do {
                switch kind {
                case .translate: try await translateAll(entries, target: target, method: method, session: session, jobID: newJob.id)
                case .polish: try await polishAll(entries, target: target, method: method, session: session, jobID: newJob.id)
                }
            } catch is CancellationError {
            } catch {
                setError(error.localizedDescription, jobID: newJob.id)
            }
            if job?.id == newJob.id {
                job = nil
                task = nil
            }
        }
    }

    /// 只有仍是这个任务时才写错误(被取消后再开的新任务不受旧任务体影响)。
    private func setError(_ message: String, jobID: UUID) {
        guard job?.id == jobID else { return }
        error = message
    }

    private func translateAll(_ entries: [CaptionTranscript.Entry], target: TargetLanguage,
                              method: TranslationMethod, session: UUID, jobID: UUID) async throws {
        let plan = translation.plan(entries.map { .init(id: $0.id, text: $0.text) }, target: target, method: method)
        let writer = ResultWriter(subtitles: subtitles, target: target, polished: false, session: session)
        writer.add(Dictionary(uniqueKeysWithValues: plan.skipped.map { ($0, "") }))
        advance(plan.skipped.count, jobID: jobID)
        let limit = max(1, translation.limits(for: method).maxConcurrent)
        let contexts = context(for: plan.chunks.map { $0.items.first?.id }, entries: entries)

        // 固定数量的工作任务从队列里取块(并发上限 = 这种方式允许的并发数,闸门再管 QPS)。
        let queue = ChunkQueue(chunks: plan.chunks, contexts: contexts)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<limit {
                group.addTask { try await self.work(queue, writer: writer, method: method, jobID: jobID) }
            }
            do {
                try await group.waitForAll()
            } catch {
                writer.flush()
                throw error
            }
        }
        writer.flush()
    }

    private func polishAll(_ entries: [CaptionTranscript.Entry], target: TargetLanguage,
                           method: TranslationMethod, session: UUID, jobID: UUID) async throws {
        let model: String = if case .llm(let model) = method { model } else { "" }
        let writer = ResultWriter(subtitles: subtitles, target: target, polished: true, session: session)
        let all = subtitles.transcript.entries
        let position = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        for start in stride(from: 0, to: entries.count, by: Self.polishChunk) {
            try Task.checkCancellation()
            let chunk = Array(entries[start..<min(start + Self.polishChunk, entries.count)])
            let first = position[chunk[0].id] ?? 0
            let context = all[max(0, first - 3)..<first].map { ContextLine(source: $0.text, translation: $0.translation) }
            do {
                let items = chunk.map { ContextLine(source: $0.text, translation: $0.translation ?? "") }
                let refined = try await translation.refine(items, context: context, target: target, model: model)
                writer.add(Dictionary(uniqueKeysWithValues: zip(chunk.map(\.id), refined).map { ($0, $1) }))
            } catch is CancellationError {
                throw CancellationError()
            } catch LLMError.empty {
                // 模型没按编号输出:这一块保持原译文,继续下一块。
                setError(String(localized: "部分句子 AI 没有按要求返回，保留了原来的译文", bundle: .l10n), jobID: jobID)
            }
            advance(chunk.count, jobID: jobID)
        }
        writer.flush()
    }

    /// 一个工作任务:依次取块翻译,结果交给 writer;致命错误抛出(停止整批),其他错误只标记这几句失败。
    private func work(_ queue: ChunkQueue, writer: ResultWriter, method: TranslationMethod, jobID: UUID) async throws {
        while let (chunk, context) = queue.next() {
            try Task.checkCancellation()
            do {
                // translateChunk 已把"原样返回 → 不需要译文"和简体归一化做好,直接按序写回。
                let translations = try await translation.translateChunk(chunk, method: method, context: context)
                writer.add(Dictionary(uniqueKeysWithValues: zip(chunk.items.map(\.id), translations)))
            } catch {
                if Self.abortsBatch(error) { throw error }
                writer.fail(chunk.items.map(\.id))
                setError(error.localizedDescription, jobID: jobID)
            }
            advance(chunk.items.count, jobID: jobID)
        }
    }

    /// 重试也不会成功、应该停下整批的错误(取消、密钥、额度、方式不可用、系统翻译语言包没装)。
    private static func abortsBatch(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? MachineTranslationError { return error.abortsBatch }
        if error is SystemTranslator.TranslatorError { return true }
        if case TranslationService.TranslationError.unavailable = error { return true }
        return false
    }

    /// 更新进度。先取出整份 Job、算好再整体写回:`@Observable` 的属性在 `job?.done = …` 赋值期间独占 `job`,
    /// 等号右边再读 `job` 会触发 Swift 独占访问检查直接崩溃(实测:翻译完一块更新进度时 SIGABRT)。
    private func advance(_ count: Int, jobID: UUID) {
        guard count > 0, var current = job, current.id == jobID else { return }
        current.done = min(current.done + count, current.total)
        job = current
    }

    /// 每块第一句之前的 3 句(原文 + 已有译文),给 AI 作上下文。
    private func context(for firstIDs: [UUID?], entries: [CaptionTranscript.Entry]) -> [[ContextLine]] {
        let all = subtitles.transcript.entries
        let position = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        return firstIDs.map { id in
            guard let id, let index = position[id] else { return [] }
            return all[max(0, index - 3)..<index].map { ContextLine(source: $0.text, translation: $0.translation) }
        }
    }
}

/// 批量翻译的块队列(工作任务依次取下一块)。
@MainActor
private final class ChunkQueue {
    private let chunks: [BatchPlanner.Chunk]
    private let contexts: [[ContextLine]]
    private var index = 0

    init(chunks: [BatchPlanner.Chunk], contexts: [[ContextLine]]) {
        self.chunks = chunks
        self.contexts = contexts
    }

    func next() -> (BatchPlanner.Chunk, [ContextLine])? {
        guard index < chunks.count else { return nil }
        defer { index += 1 }
        return (chunks[index], contexts[index])
    }
}

/// 把结果攒一会儿再写回记录:记录窗口从第一处变化开始重排,每块都写会让长记录反复重排。
@MainActor
private final class ResultWriter {
    private let subtitles: SubtitleController
    private let target: TargetLanguage
    private let polished: Bool
    private let session: UUID
    private var pending: [UUID: String] = [:]
    private var failed: Set<UUID> = []
    private var lastFlush = Date.distantPast

    init(subtitles: SubtitleController, target: TargetLanguage, polished: Bool, session: UUID) {
        self.subtitles = subtitles
        self.target = target
        self.polished = polished
        self.session = session
    }

    func add(_ updates: [UUID: String]) {
        pending.merge(updates) { $1 }
        if Date().timeIntervalSince(lastFlush) > 0.3 { flush() }
    }

    func fail(_ ids: [UUID]) {
        failed.formUnion(ids)
    }

    func flush() {
        subtitles.applyTranslations(pending, failed: failed, target: target, polished: polished, session: session)
        pending = [:]
        failed = []
        lastFlush = Date()
    }
}
