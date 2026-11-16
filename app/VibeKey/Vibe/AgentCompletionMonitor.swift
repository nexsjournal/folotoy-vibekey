import Foundation

/// 从一个 Agent 的本地终态记录中提取出的完成事件。
nonisolated struct AgentCompletionEvent: Equatable, Sendable {
    let source: String
    let reply: String
    let project: String?
    let threadID: UUID?
    let turnID: String?
    let deduplicationKey: String
}

nonisolated struct AgentLogCompletion: Equatable, Sendable {
    let event: AgentCompletionEvent
    let completedAt: Date?
}

/// 解析各 Agent 已经写入本机的最终回复。只认识明确的“本轮完成”记录，不把中间工具调用当结果。
nonisolated enum AgentCompletionLogParser {
    static func codex(_ object: [String: Any], fileURL: URL, project: String? = nil) -> AgentLogCompletion? {
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "task_complete" else { return nil }
        let message = clean(payload["last_agent_message"] as? String)
        let failure = errorText(payload["error"])
        let reply = !message.isEmpty ? message : (failure.map { "执行失败：\($0)" } ?? "")
        guard !reply.isEmpty else { return nil }
        let thread = payload["thread_id"] as? String
            ?? payload["session_id"] as? String
            ?? lastUUID(in: fileURL.lastPathComponent)?.uuidString
        let threadID = thread.flatMap(UUID.init(uuidString:))
        let turnID = payload["turn_id"] as? String
        let identity = turnID ?? stringValue(object["timestamp"])
        let key = "codex:\(threadID?.uuidString ?? fileURL.lastPathComponent):\(identity)"
        let event = AgentCompletionEvent(
            source: "Codex", reply: reply, project: project,
            threadID: threadID, turnID: turnID, deduplicationKey: key
        )
        return .init(event: event, completedAt: AgentTimestamp.parse(object["timestamp"] as? String))
    }

    static func claudeCode(_ object: [String: Any], fileURL: URL) -> AgentLogCompletion? {
        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let stop = message["stop_reason"] as? String,
              stop == "end_turn" || stop == "stop_sequence",
              let reply = textContent(message["content"]) else { return nil }
        let session = object["sessionId"] as? String ?? fileURL.deletingPathExtension().lastPathComponent
        let messageID = object["uuid"] as? String ?? "\(object["timestamp"] ?? "")"
        return .init(
            event: .init(
                source: "Claude Code", reply: reply,
                project: projectName(object["cwd"] as? String),
                threadID: nil, turnID: messageID,
                deduplicationKey: "claude:\(session):\(messageID)"
            ),
            completedAt: AgentTimestamp.parse(object["timestamp"] as? String)
        )
    }

    static func deepSeek(_ object: [String: Any], fileURL: URL) -> AgentLogCompletion? {
        guard let record = object["record"] as? [String: Any],
              let rows = record["rows"] as? [String: Any],
              let stats = rowValue(rows, "sessionStats") else { return nil }
        // openStep / pendingCalls 清零才是一轮结束；会话文件在过程中会反复重写。
        if let openStep = stats["openStep"], !(openStep is NSNull) { return nil }
        if let pending = stats["pendingCalls"] as? [String: Any], !pending.isEmpty { return nil }
        guard let outline = rowValue(rows, "turnOutline"),
              let turns = outline["turns"] as? [[String: Any]],
              let last = turns.last else { return nil }
        let reply = clean(last["response"] as? String)
        guard !reply.isEmpty else { return nil }
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let session = stem.hasPrefix("session-") ? String(stem.dropFirst("session-".count)) : stem
        let turn = (last["turn"] as? NSNumber)?.stringValue ?? "\(turns.count)"
        let cwd = (record["identity"] as? [String: Any])?["cwd"] as? String
        let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return .init(
            event: .init(
                source: "DeepSeek", reply: reply, project: projectName(cwd),
                threadID: nil, turnID: turn,
                deduplicationKey: "deepseek:\(session):\(turn)"
            ),
            completedAt: modified
        )
    }

    static func zcode(_ object: [String: Any]) -> AgentLogCompletion? {
        guard object["type"] as? String == "model_io",
              let response = object["response"] as? [String: Any],
              response["finishReason"] as? String == "stop" else { return nil }
        let reply = clean(response["text"] as? String)
        guard !reply.isEmpty else { return nil }
        let session = object["sessionId"] as? String ?? ""
        let turn = object["turnId"] as? String ?? ""
        let responseID = object["requestId"] as? String ?? object["completedAt"] as? String ?? UUID().uuidString
        return .init(
            event: .init(
                source: "ZCode", reply: reply, project: nil,
                threadID: nil, turnID: turn,
                deduplicationKey: "zcode:\(session):\(turn):\(responseID)"
            ),
            completedAt: AgentTimestamp.parse(object["completedAt"] as? String)
        )
    }

    static func workBuddy(_ object: [String: Any], fileURL: URL) -> AgentLogCompletion? {
        guard object["type"] as? String == "message",
              (object["role"] as? String) == "assistant",
              (object["status"] as? String) == "completed",
              let reply = textContent(object["content"]) else { return nil }
        let session = object["sessionId"] as? String ?? fileURL.deletingPathExtension().lastPathComponent
        let provider = object["providerData"] as? [String: Any]
        let messageID = provider?["messageId"] as? String ?? object["id"] as? String ?? "\(object["timestamp"] ?? "")"
        return .init(
            event: .init(
                source: "WorkBuddy", reply: reply,
                project: projectName(object["cwd"] as? String),
                threadID: nil, turnID: messageID,
                deduplicationKey: "workbuddy:\(session):\(messageID)"
            ),
            completedAt: AgentTimestamp.parse(object["timestamp"] as? String)
        )
    }

    private static func rowValue(_ rows: [String: Any], _ key: String) -> [String: Any]? {
        (rows[key] as? [String: Any])?["val"] as? [String: Any]
    }

    private static func textContent(_ value: Any?) -> String? {
        if let raw = value as? String {
            let text = clean(raw)
            if !text.isEmpty { return text }
        }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let content = blocks.compactMap { block -> String? in
            let type = block["type"] as? String
            guard type == nil || type == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
        let result = clean(content)
        return result.isEmpty ? nil : result
    }

    private static func errorText(_ value: Any?) -> String? {
        if let raw = value as? String {
            let text = clean(raw)
            if !text.isEmpty { return text }
        }
        if let object = value as? [String: Any], let raw = object["message"] as? String {
            let text = clean(raw)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func stringValue(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func projectName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : String(name.prefix(30))
    }

    private static func lastUUID(in value: String) -> UUID? {
        let pattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).last,
              let range = Range(match.range, in: value) else { return nil }
        return UUID(uuidString: String(value[range]))
    }
}

/// 轮询各 Agent 的本地终态记录；完成即回调，基线阶段不重放历史任务。
@MainActor
final class AgentCompletionMonitor {
    private let scanner = LocalAgentCompletionScanner()
    private var task: Task<Void, Never>?
    private let onCompletion: @MainActor (AgentCompletionEvent) -> Void

    init(onCompletion: @escaping @MainActor (AgentCompletionEvent) -> Void) {
        self.onCompletion = onCompletion
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await scanner.prime()
            while !Task.isCancelled {
                let events = await scanner.scan()
                for event in events { onCompletion(event) }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

private actor LocalAgentCompletionScanner {
    private struct Pending {
        let completion: AgentLogCompletion
        let observedAt: Date
        let modifiedAt: Date
    }

    private let startedAt = Date()
    private var initialized = false
    private var offsets: [String: UInt64] = [:]
    private var modifiedAt: [String: Date] = [:]
    private var pending: [String: Pending] = [:]
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var scanCount = 0

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var codexRoot: URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }
    private var claudeRoot: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
    private var zcodeRoot: URL { home.appendingPathComponent(".zcode/cli/rollout", isDirectory: true) }
    private var workBuddyRoot: URL { home.appendingPathComponent(".workbuddy/projects", isDirectory: true) }
    private var deepSeekRoot: URL { home.appendingPathComponent(".dsh/storages/session_projcache/sessions", isDirectory: true) }

    func prime() async {
        guard !initialized else { return }
        let cutoff = startedAt.addingTimeInterval(-7 * 86_400)
        for file in files(in: codexRoot, extension: "jsonl", after: cutoff)
            + files(in: claudeRoot, extension: "jsonl", after: cutoff)
            + files(in: zcodeRoot, extension: "jsonl", after: cutoff)
            + files(in: workBuddyRoot, extension: "jsonl", after: cutoff) {
            offsets[file.path] = safeEndOffset(of: file)
        }
        for file in files(in: deepSeekRoot, extension: "json", after: cutoff) {
            if let object = jsonObject(file), let completion = AgentCompletionLogParser.deepSeek(object, fileURL: file) {
                rememberWithoutEmitting(completion.event.deduplicationKey)
            }
            modifiedAt[file.path] = modificationDate(file)
        }
        initialized = true
    }

    func scan() async -> [AgentCompletionEvent] {
        if !initialized { await prime() }
        scanCount += 1
        let now = Date()
        var events: [AgentCompletionEvent] = []

        for file in recentAppendFiles(root: codexRoot, after: startedAt.addingTimeInterval(-300)) {
            let project = codexSessionProject(file)
            for item in newObjects(in: file) {
                guard let completion = AgentCompletionLogParser.codex(item, fileURL: file, project: project) else { continue }
                enqueueImmediate(completion, file: file, events: &events)
            }
        }
        for file in recentAppendFiles(root: claudeRoot, after: startedAt.addingTimeInterval(-300)) {
            for item in newObjects(in: file) {
                guard let completion = AgentCompletionLogParser.claudeCode(item, fileURL: file) else { continue }
                enqueueImmediate(completion, file: file, events: &events)
            }
        }
        for file in recentAppendFiles(root: zcodeRoot, after: startedAt.addingTimeInterval(-300)) {
            for item in newObjects(in: file) {
                guard let completion = AgentCompletionLogParser.zcode(item) else { continue }
                enqueueImmediate(completion, file: file, events: &events)
            }
        }
        for file in recentAppendFiles(root: workBuddyRoot, after: startedAt.addingTimeInterval(-300)) {
            if let completion = newObjects(in: file)
                .compactMap({ AgentCompletionLogParser.workBuddy($0, fileURL: file) }).last {
                deferStable(completion, file: file, now: now)
            }
        }
        for file in files(in: deepSeekRoot, extension: "json", after: startedAt.addingTimeInterval(-300)) {
            let currentModified = modificationDate(file)
            guard modifiedAt[file.path] != currentModified else { continue }
            modifiedAt[file.path] = currentModified
            if let object = jsonObject(file),
               let completion = AgentCompletionLogParser.deepSeek(object, fileURL: file) {
                deferStable(completion, file: file, now: now)
            }
        }
        flushStable(now: now, events: &events)
        if scanCount % 120 == 0 { compactSeen() }
        return events
    }

    private func enqueueImmediate(
        _ completion: AgentLogCompletion,
        file: URL,
        events: inout [AgentCompletionEvent]
    ) {
        let date = completion.completedAt ?? modificationDate(file)
        guard date >= startedAt.addingTimeInterval(-5), !seen.contains(completion.event.deduplicationKey) else { return }
        remember(completion.event.deduplicationKey)
        events.append(completion.event)
    }

    private func deferStable(_ completion: AgentLogCompletion, file: URL, now: Date) {
        guard !seen.contains(completion.event.deduplicationKey) else { return }
        pending[file.path] = .init(
            completion: completion,
            observedAt: now,
            modifiedAt: modificationDate(file)
        )
    }

    private func flushStable(now: Date, events: inout [AgentCompletionEvent]) {
        for (path, item) in pending {
            let currentModified = modificationDate(URL(fileURLWithPath: path))
            guard now.timeIntervalSince(item.observedAt) >= 1.2,
                  abs(currentModified.timeIntervalSince(item.modifiedAt)) < 0.001 else { continue }
            pending.removeValue(forKey: path)
            let date = item.completion.completedAt ?? currentModified
            guard date >= startedAt.addingTimeInterval(-5),
                  !seen.contains(item.completion.event.deduplicationKey) else { continue }
            remember(item.completion.event.deduplicationKey)
            events.append(item.completion.event)
        }
    }

    private func rememberWithoutEmitting(_ key: String) {
        guard seen.insert(key).inserted else { return }
        seenOrder.append(key)
    }

    private func remember(_ key: String) {
        rememberWithoutEmitting(key)
    }

    private func compactSeen() {
        guard seenOrder.count > 1_024 else { return }
        let remove = seenOrder.prefix(seenOrder.count - 1_024)
        remove.forEach { seen.remove($0) }
        seenOrder.removeFirst(remove.count)
    }

    private func recentAppendFiles(root: URL, after date: Date) -> [URL] {
        files(in: root, extension: "jsonl", after: date)
    }

    private func files(in root: URL, extension fileExtension: String, after date: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == fileExtension else { continue }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified >= date else { continue }
            result.append(file)
        }
        return result
    }

    private func jsonObject(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func newObjects(in file: URL) -> [[String: Any]] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = (attributes?[.size] as? NSNumber)?.uint64Value else { return [] }
        var start = offsets[file.path] ?? 0
        if size < start { start = 0 }
        guard size > start else { return [] }

        let maximumRead = UInt64(16 * 1_024 * 1_024)
        if size - start > maximumRead { start = size - maximumRead }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[...lastNewline]
        offsets[file.path] = start + UInt64(complete.count)
        return complete.split(separator: 0x0A).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
    }

    private func safeEndOffset(of file: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0, let handle = try? FileHandle(forReadingFrom: file) else { return size }
        defer { try? handle.close() }
        let start = size > 64 * 1_024 ? size - 64 * 1_024 : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: 0x0A) else { return start }
        return start + UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)
    }

    private func modificationDate(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private func codexSessionProject(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1_024) else { return nil }
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let cwd = payload["cwd"] as? String else { continue }
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? nil : String(name.prefix(30))
        }
        return nil
    }
}
