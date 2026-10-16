import Foundation

/// 运行 esptool 子进程,逐行回调输出(stdout 与 stderr 合并),并从输出里解析百分比进度。
nonisolated enum EsptoolRunner {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    /// 执行一次 esptool;`onProgress` 收到 0...1 的进度。可通过取消 Task 终止子进程。
    static func run(_ tool: URL, arguments: [String], onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = OutputCollector(onProgress: onProgress)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                process.terminationHandler = { p in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: Result(status: p.terminationStatus, output: collector.text))
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// 从一行输出里取最后一个百分比,例如 "Writing at 0x00010000 [====>   ] 35.2% 442368/1251760 bytes"。
    static func progress(in line: String) -> Double? {
        guard let match = line.matches(of: /(\d{1,3}(?:\.\d+)?)\s?%/).last,
              let value = Double(match.output.1) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    /// 解析 `read-mac` 输出中的 MAC 地址(去掉冒号)。
    static func mac(in output: String) -> String? {
        guard let match = output.firstMatch(of: /MAC:\s*([0-9a-fA-F:]{17})/) else { return nil }
        return String(match.output.1).replacingOccurrences(of: ":", with: "").lowercased()
    }
}

/// 线程安全地累积子进程输出并按行报告进度(esptool 用 \r 刷新进度条,所以 \r 也当作换行)。
nonisolated private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private(set) var all = ""
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    var text: String { lock.withLock { all } }

    func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            all += chunk
            buffer += chunk
            let parts = buffer.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            buffer = String(parts.last ?? "")
            lines = parts.dropLast().map(String.init)
        }
        for line in lines {
            if let p = EsptoolRunner.progress(in: line) { onProgress(p) }
        }
    }
}
