import Foundation

/// 一次字幕会话的完整记录:每句定稿的原文、译文和时间。
/// 字幕条只显示最后几句;记录窗口显示全部,结束时可以保存成文本文件。
/// 纯数据类型,格式化函数没有副作用,便于测试。
nonisolated struct CaptionTranscript: Equatable, Sendable {
    /// 一句字幕。
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        /// 开始说这段话的时间(这段话第一次出现识别结果的时刻)。显示 / 导出用它;同一次定稿切出的几句时间相同。
        /// 记录窗口里正在说的一段一出现就按这个时间显示,定稿后时间不变,行就不会跳。
        let time: Date
        /// 定稿时间(字幕记录窗口据此判断实时翻译是否还在处理这句)。
        let finalizedAt: Date
        var text: String
        var translation: String?
        /// 翻译请求失败(超时 / 出错),不再等待译文。
        var translationFailed = false
        /// 译文是按哪个目标语言翻译的(字幕记录窗口据此判断换了语言后哪些句子需要重新翻译)。
        var translationTarget: TargetLanguage?
        /// 译文已经过 AI 润色。
        var translationPolished = false

        /// 翻译已有结果(成功或失败)。
        var translationSettled: Bool { translation != nil || translationFailed }

        /// `finalizedAt` 不给时等于 `time`(测试、示例数据)。
        init(id: UUID = UUID(), time: Date = Date(), finalizedAt: Date? = nil, text: String, translation: String? = nil) {
            self.id = id
            self.time = time
            self.finalizedAt = finalizedAt ?? time
            self.text = text
            self.translation = translation
        }
    }

    /// 正在说、还没定稿的一段话:开始说时就有时间,定稿后成为句子(`commit`)、时间不变,
    /// 记录窗口里这一行因此只换颜色、不换位置。实例由 SubtitleController 持有,不放进记录里——
    /// 它每秒变化好几次,放进记录会让观察记录的翻译工具条、总结等反复重算。
    struct Live: Equatable, Sendable {
        let startedAt: Date
        var text: String
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

    /// 定稿一段话:每句一条记录,时间 = 这段开始说的时间(没有未定稿内容时取 `now`),定稿时间 = `now`。
    /// 同一次定稿的句子时间是同一个值,记录窗口据此把它们合成一段。返回新句子(字幕条关联和翻译要用它们的 id)。
    @discardableResult
    mutating func commit(_ sentences: [String], startedAt: Date?, now: Date = Date()) -> [Entry] {
        let time = startedAt ?? now
        let added = sentences.map { Entry(time: time, finalizedAt: now, text: $0) }
        added.forEach { append($0) }
        return added
    }

    /// 译文异步到达后补到对应的句子上。空字符串表示原文已是目标语言、不需要译文。
    mutating func setTranslation(_ translation: String, for id: UUID, target: TargetLanguage) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].translation = translation
        entries[index].translationTarget = target
        entries[index].translationFailed = false
        entries[index].translationPolished = false
    }

    /// 批量写入译文(字幕记录窗口的批量翻译 / AI 润色):先建索引再写,长记录也是线性时间。
    mutating func setTranslations(_ translations: [UUID: String], failed: Set<UUID> = [], target: TargetLanguage, polished: Bool = false) {
        guard !translations.isEmpty || !failed.isEmpty else { return }
        let index = Dictionary(entries.indices.map { (entries[$0].id, $0) }, uniquingKeysWith: { _, last in last })
        for (id, translation) in translations {
            guard let i = index[id] else { continue }
            entries[i].translation = translation
            entries[i].translationTarget = target
            entries[i].translationFailed = false
            entries[i].translationPolished = polished
        }
        for id in failed {
            guard let i = index[id], entries[i].translation == nil else { continue }
            entries[i].translationFailed = true
        }
    }

    mutating func setTranslationFailed(for id: UUID) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].translationFailed = true
    }

    /// 清掉译文(换了目标语言、要重新翻译时)。
    mutating func clearTranslation(for id: UUID) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].translation = nil
        entries[index].translationTarget = nil
        entries[index].translationPolished = false
        entries[index].translationFailed = false
    }

    /// 标记前 `count` 句已保存(默认全部)。
    mutating func markSaved(upTo count: Int? = nil) {
        savedCount = max(savedCount, min(count ?? entries.count, entries.count))
    }

    /// 某个时刻相对会话开始的时间,格式 `HH:mm:ss`。
    func offset(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// 某句的时间(开始说这段话的时间)。
    func offset(of entry: Entry) -> String { offset(at: entry.time) }

    /// 正在说的一段的时间(定稿后这段的时间与它相同)。
    func offset(of live: Live) -> String { offset(at: live.startedAt) }

    // MARK: - 分段显示

    /// 显示用的一段:同一次定稿的相邻句子(`time` 相同)合成一段。
    /// 识别引擎常把一大段话一次定稿、再切成几句,逐句列出会出现一串重复的时间;
    /// 合成一段更接近说话的自然段落,也和定稿前正在说的那一行一一对应(定稿后原位变色,不会并进上一段)。
    /// 数据仍按句保存(翻译、润色都按句进行),只在显示 / 导出时合并。
    struct Paragraph: Equatable, Sendable {
        /// 段内句子在 `entries` 中的下标范围。
        let range: Range<Int>
    }

    /// 把全部句子分段:相邻句子 `time` 不同处切开(线性时间,长记录也很快)。
    func paragraphs() -> [Paragraph] {
        var result: [Paragraph] = []
        var start = 0
        for index in entries.indices.dropFirst() where entries[index].time != entries[index - 1].time {
            result.append(Paragraph(range: start..<index))
            start = index
        }
        if !entries.isEmpty { result.append(Paragraph(range: start..<entries.count)) }
        return result
    }

    /// 一段的时间(取段内第一句)。
    func offset(of paragraph: Paragraph) -> String { offset(of: entries[paragraph.range.lowerBound]) }

    /// 一段的原文:各句按语言习惯拼接(中日韩之间不加空格,拉丁文字之间加空格)。
    func text(of paragraph: Paragraph) -> String {
        TranscriptText.join(entries[paragraph.range].map(\.text))
    }

    /// 一段的译文:已有译文的句子拼接起来;都还没有(或都不需要)译文时为 nil。
    func translation(of paragraph: Paragraph) -> String? {
        let parts = entries[paragraph.range].compactMap(\.translation).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : TranscriptText.join(parts)
    }

    /// 导出为纯文本:标题行 +(有的话)AI 总结 + 每段 `[时间] 原文`,译文缩进在下一行(分段规则同记录窗口)。
    func plainText(includeTranslation: Bool = true, summary: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var lines = [appName, formatter.string(from: startedAt), ""]
        if let summary, !summary.isEmpty {
            lines += [String(localized: "【AI 总结】", bundle: .l10n), summary, "", String(localized: "【字幕】", bundle: .l10n)]
        }
        for paragraph in paragraphs() {
            lines.append("[\(offset(of: paragraph))] \(text(of: paragraph))")
            if includeTranslation, let translation = translation(of: paragraph) {
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
