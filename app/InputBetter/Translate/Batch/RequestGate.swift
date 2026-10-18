import Foundation

/// 请求闸门:限制同一服务的并发数和请求间隔(QPS)。字幕实时翻译和字幕记录批量翻译共用一个闸门,
/// 避免两边同时请求超出服务商的频率限制(例如百度标准版 1 QPS)。
/// 等待期间任务被取消时立即抛出 CancellationError。actor 的方法在 await 处可重入,所以每次醒来都重新检查条件。
actor RequestGate {
    private let maxConcurrent: Int
    private let minInterval: TimeInterval
    private var active = 0
    private var lastStart = Date.distantPast

    init(limits: BatchLimits) {
        maxConcurrent = max(1, limits.maxConcurrent)
        minInterval = limits.minInterval
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        while true {
            try Task.checkCancellation()
            let wait = minInterval - Date().timeIntervalSince(lastStart)
            if active < maxConcurrent, wait <= 0 { break }
            try await Task.sleep(for: .milliseconds(max(20, Int((wait > 0 ? wait : 0.03) * 1000))))
        }
        active += 1
        lastStart = Date()
        defer { active -= 1 }
        return try await operation()
    }
}
