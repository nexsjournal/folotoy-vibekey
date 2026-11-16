import Foundation
import Darwin

/// Hook 的临时文件只以随机 UUID 寻址，读取后立即删除；正文不进入 URL 或日志。
nonisolated enum AgentCompletionInbox {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/FoloVibeKey/AgentInbox", isDirectory: true)
    }

    /// 异常退出时清理超过一天的临时文件；只处理本收件箱里的 UUID 文件。
    static func removeExpired(now: Date = Date()) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for file in files where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  values.isSymbolicLink != true, let date = values.contentModificationDate,
                  now.timeIntervalSince(date) > 86_400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func consume(_ token: String, directory: URL = directory) -> String? {
        guard let id = UUID(uuidString: token), id.uuidString == token.uppercased() else { return nil }
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 2_097_152 else { close(fd); return nil }
        unlink(url.path)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd(),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = json["last_assistant_message"] as? String else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// 将最终回复缩成设备可读的文本；网络总结不可用时抽取原文重点，避免编造结果。
nonisolated enum AgentCompletionSummary {
    static func fallback(_ text: String) -> String {
        let full = clean(text)
        guard full.count > 360 else { return full }
        // 按原文句子抽取：首句交代结果，分别保留最重要的阻碍与下一步，末句补充收尾。
        // 仅截取原文，不推断成功与否；找不到句界时退回首尾。
        let split = text.replacingOccurrences(of: #"(?<=[。！？!?；;])|(?<=\.)\s+"#,
                                             with: "\n", options: .regularExpression)
        let parts = split.components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
        guard parts.count > 1 else {
            return String(full.prefix(200)) + " … " + String(full.suffix(157))
        }
        let issues = ["未完成", "失败", "错误", "无法", "未能", "阻塞", "风险", "未验证", "failed", "failure", "error", "unable", "blocked", "cannot", "not verified"]
        let actions = ["下一步", "请先", "请在", "需要", "必须", "请确认", "请重新", "next step", "please", "need to", "requires", "confirm", "retry"]
        func bestIndex(_ terms: [String]) -> Int? {
            parts.indices.filter { $0 != 0 && $0 != parts.count - 1 }.max { left, right in
                let a = parts[left].lowercased(), b = parts[right].lowercased()
                let scoreA = terms.reduce(0) { $0 + (a.contains($1) ? 1 : 0) }
                let scoreB = terms.reduce(0) { $0 + (b.contains($1) ? 1 : 0) }
                return scoreA == scoreB ? left > right : scoreA < scoreB
            }.flatMap { index in terms.contains(where: parts[index].lowercased().contains) ? index : nil }
        }
        var indices: Set<Int> = [0, parts.count - 1]
        if let issue = bestIndex(issues) { indices.insert(issue) }
        if let action = bestIndex(actions) { indices.insert(action) }
        let ordered = indices.sorted()
        let limit = max(1, (360 - (ordered.count - 1) * 3) / ordered.count)
        return ordered.map { index in
            let part = parts[index]
            guard part.count > limit else { return part }
            // 命中词不在句首时，保留词前上下文，避免把关键的失败/待办截掉。
            let lower = part.lowercased()
            let ranges = (issues + actions).compactMap { lower.range(of: $0) }
            if index != 0 && index != parts.count - 1,
               let hit = ranges.min(by: { $0.lowerBound < $1.lowerBound }) {
                let offset = lower.distance(from: lower.startIndex, to: hit.lowerBound)
                let start = part.index(part.startIndex, offsetBy: max(0, offset - 20))
                return (offset > 20 ? "…" : "") + String(part[start...].prefix(max(1, limit - 2))) + "…"
            }
            return index == parts.count - 1 ? "…" + String(part.suffix(limit - 1)) : String(part.prefix(limit - 1)) + "…"
        }.joined(separator: " · ")
    }

    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}\s+|[-*]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 列表行内宽约 164px；按半角列切分，留出字体和标点的余量，避免固件再截断。
    static func pages(_ text: String) -> [[String]] {
        let clean = clean(text)
        var lines: [String] = []
        var line = ""
        var columns = 0
        for character in clean {
            // Montserrat 的 W/M 可能接近汉字宽，按等宽上限切分以免长英文被省略。
            let width = 2
            if columns + width > 22 || (line + String(character)).utf8.count > HostCommand.listTextMaxBytes {
                if !line.isEmpty { lines.append(line.trimmingCharacters(in: .whitespaces)) }
                line = ""
                columns = 0
            }
            if line.isEmpty && character.isWhitespace { continue }
            line.append(character)
            columns += width
        }
        if !line.isEmpty { lines.append(line.trimmingCharacters(in: .whitespaces)) }
        guard !lines.isEmpty else { return [] }
        return stride(from: 0, to: lines.count, by: HostCommand.listVisibleRows).map {
            Array(lines[$0..<min($0 + HostCommand.listVisibleRows, lines.count)])
        }
    }

    static func modelInput(_ text: String) -> String {
        guard text.count > 12_000 else { return text }
        return String(text.prefix(6_000)) + "\n…\n" + String(text.suffix(6_000))
    }
}
