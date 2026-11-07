import Foundation

/// 一场字幕里"整句译文"的请求入口(系统翻译 / 在线服务;AI 走逐字流式,不经过这里)。
/// - 去重:字幕条的句子(识别中确认)和字幕记录的句子(定稿)多数文字相同,同一句只请求一次,结果共享;
/// - 合并:很短时间内到达的多句(一次定稿常有好几句)合成一次批量请求,省请求次数,也不容易触发 QPS 限制。
/// 生命周期:新的一场字幕、换目标语言或翻译方式时 `reset`:清空缓存、取消还没发出和已发出的请求
/// (在线服务不再白白消耗额度),等待中的调用方得到 `.cancelled`(调用方本来也会按代数丢弃)。
@MainActor
final class SentenceTranslator {
    enum Result: Equatable, Sendable {
        case translated(String)
        /// 原文已是目标语言。
        case sameLanguage
        case failed(String)
        /// reset 时被取消(换了设置或字幕结束),调用方忽略即可。
        case cancelled
    }

    private struct Pending {
        let text: String
        let target: TargetLanguage
        let method: TranslationMethod
        let continuation: CheckedContinuation<Result, Never>
    }

    private let service: TranslationService
    private var cache: [String: Task<Result, Never>] = [:]
    private var queue: [Pending] = []
    private var flushTask: Task<Void, Never>?
    /// 已发出、还没返回的批量请求(reset 时取消)。
    private var inflight: Set<Task<Void, Never>> = []

    /// 等多久把到达的句子合成一批(足够短,不影响跟上语音)。
    private static let coalesceDelay: Duration = .milliseconds(60)
    /// 缓存上限(一场字幕很长时整体清空,避免无限增长)。
    private static let maxCache = 600

    init(service: TranslationService) {
        self.service = service
    }

    func reset() {
        cache = [:]
        flushTask?.cancel()
        flushTask = nil
        let pending = queue
        queue = []
        pending.forEach { $0.continuation.resume(returning: .cancelled) }
        inflight.forEach { $0.cancel() }
        inflight = []
    }

    func translate(_ text: String, target: TargetLanguage, method: TranslationMethod) async -> Result {
        let key = "\(method.storage)|\(target.rawValue)|\(Self.normalize(text))"
        if let task = cache[key] { return await task.value }
        if cache.count >= Self.maxCache { cache = [:] }
        let task = Task { await self.enqueue(text, target: target, method: method) }
        cache[key] = task
        let result = await task.value
        // 失败的不缓存,下次可以重试。
        if case .failed = result { cache[key] = nil }
        return result
    }

    /// 去掉大小写、标点和空白差异(识别中和定稿的同一句常常只差标点)。
    static func normalize(_ text: String) -> String {
        CaptionSegmenter.tokenize(text).map(\.word).joined(separator: " ")
    }

    // MARK: - 合并请求

    private func enqueue(_ text: String, target: TargetLanguage, method: TranslationMethod) async -> Result {
        await withCheckedContinuation { continuation in
            queue.append(Pending(text: text, target: target, method: method, continuation: continuation))
            if flushTask == nil {
                flushTask = Task {
                    try? await Task.sleep(for: Self.coalesceDelay)
                    // reset 取消了这次合并:队列已经被清空并回复 .cancelled,不要再清掉之后新建的 flushTask。
                    guard !Task.isCancelled else { return }
                    self.flush()
                }
            }
        }
    }

    private func flush() {
        flushTask = nil
        let batch = queue
        queue = []
        // 按(方式, 目标语言)分组,每组一次批量请求(TranslationService 内部再按服务的上限切块)。
        var groups: [String: [Pending]] = [:]
        for item in batch { groups["\(item.method.storage)|\(item.target.rawValue)", default: []].append(item) }
        for group in groups.values {
            guard let first = group.first else { continue }
            let items = group.map { BatchPlanner.Item(id: UUID(), text: $0.text) }
            var task: Task<Void, Never>!
            task = Task {
                defer { inflight.remove(task) }
                do {
                    let results = try await service.translateBatch(items, target: first.target, method: first.method)
                    for (item, pending) in zip(items, group) {
                        let text = results[item.id] ?? ""
                        pending.continuation.resume(returning: text.isEmpty ? .sameLanguage : .translated(text))
                    }
                } catch is CancellationError {
                    group.forEach { $0.continuation.resume(returning: .cancelled) }
                } catch {
                    let message = error.localizedDescription
                    group.forEach { $0.continuation.resume(returning: .failed(message)) }
                }
            }
            inflight.insert(task)
        }
    }
}
