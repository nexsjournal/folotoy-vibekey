import Foundation

/// 一次字幕会话的完整记录:每句定稿的原文、译文和时间。
/// 字幕条只显示最后几句;记录窗口显示全部,结束时可以保存成文本文件。
/// 纯数据类型,格式化函数没有副作用,便于测试。
nonisolated struct CaptionTranscript: Equatable, Sendable {
    /// 一句字幕。
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        /// 定稿时间。
        let time: Date
        var text: String
        var translation: String?
        /// 翻译请求失败(超时 / 出错),不再等待译文。
        var translationFailed = false
        /// 当前译文是系统翻译的初稿,AI 润色版还在路上(界面上略暗)。
        var translationIsDraft = false

        /// 翻译已有结果(成功或失败)。
        var translationSettled: Bool { translation != nil || translationFailed }

        init(id: UUID = UUID(), time: Date = Date(), text: String, translation: String? = nil) {
            self.id = id
            self.time = time
            self.text = text
            self.translation = translation
        }
    }

    /// 会话标识:异步保存完成时用它确认记录还是同一次会话的。
    let id = UUID()
    var appName: String
    var startedAt: Date
    var endedAt: Date?
    private(set) var entries: [Entry] = []
    /// 已经保存过的句数(保存后没有新内容就不再询问)。
    private(set) var savedCount = 0

    /// 最多保留的句数(约十几个小时的连续讲话),超出后丢弃最早的句子,防止内存无限增长。
    static let maxEntries = 20_000

    init(appName: String = "", startedAt: Date = Date()) {
        self.appName = appName
        self.startedAt = startedAt
    }

    var isEmpty: Bool { entries.isEmpty }

    /// 有没有保存后新增的内容。
    var hasUnsavedEntries: Bool { entries.count > savedCount }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            entries.removeFirst(overflow)
            savedCount = max(0, savedCount - overflow)
        }
    }

    /// 译文异步到达后补到对应的句子上。空字符串表示原文已是目标语言、不需要译文。
    mutating func setTranslation(_ translation: String, for id: UUID, draft: Bool = false) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].translation = translation
        entries[index].translationIsDraft = draft
        entries[index].translationFailed = false
    }

    mutating func setTranslationFailed(for id: UUID) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].translationFailed = true
    }

    /// 清掉译文(换了目标语言、要重新翻译时)。
    mutating func clearTranslation(for id: UUID) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].translation = nil
        entries[index].translationIsDraft = false
        entries[index].translationFailed = false
    }

    /// 标记前 `count` 句已保存(默认全部)。
    mutating func markSaved(upTo count: Int? = nil) {
        savedCount = max(savedCount, min(count ?? entries.count, entries.count))
    }

    /// 某句相对会话开始的时间,格式 `HH:mm:ss`。
    func offset(of entry: Entry) -> String {
        let seconds = max(0, Int(entry.time.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// 导出为纯文本:标题行 +(有的话)AI 总结 + 每句 `[时间] 原文`,译文缩进在下一行。
    func plainText(includeTranslation: Bool = true, summary: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var lines = [appName, formatter.string(from: startedAt), ""]
        if let summary, !summary.isEmpty {
            lines += [String(localized: "【AI 总结】", bundle: .l10n), summary, "", String(localized: "【字幕】", bundle: .l10n)]
        }
        for entry in entries {
            lines.append("[\(offset(of: entry))] \(entry.text)")
            if includeTranslation, let translation = entry.translation, !translation.isEmpty {
                lines.append("           \(translation)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 保存面板里的默认文件名,如 `Google Chrome 2026-10-16 03-40.txt`(不含系统不允许的字符)。
    var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let name = appName.isEmpty ? "Captions" : appName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(name) \(formatter.string(from: startedAt)).txt"
    }
}
