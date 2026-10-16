import Foundation

/// 字幕条的数据源:原文行跟着语音实时走,译文行按句接上(RollingCaptions)。
///
/// 两条路径(按能否快速翻译选择):
/// - 快速路径(有系统翻译,或不翻译):
///   SubtitleController.handle(.partial) → partial → CaptionSegmenter.hypothesis(LocalAgreement 确认稳定的文字)
///     → 新确认的整句立即成为 CaptionUnit,系统翻译(TranslationService.quickTranslate,几十毫秒)——不用等定稿;
///   handle(.final) → final → CaptionSegmenter.final:只补上还没给出的句子。句子只增不改,不丢不重。
/// - 只有 AI 能翻译时:识别中不切句(AI 来不及),定稿后按字幕记录的句子生成 unit 并关联,
///   SubtitleController.translate → entryTranslation 把 AI 译文同步过来。
/// 每次有新内容(以及每 0.5 秒检查一次等译文超时)→ RollingCaptions.update → 原文行 / 译文行。
@MainActor @Observable
final class CaptionFeed {
    /// 字幕条的两行文字。
    private(set) var captions = RollingCaptions()
    /// 正在说、还没成句的部分。
    @ObservationIgnored private var liveRest = ""
    @ObservationIgnored private var units: [CaptionUnit] = []
    @ObservationIgnored private var segmenter = CaptionSegmenter()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let translation: TranslationService

    /// 保留的句子数上限(已显示的旧句子会被裁掉)。
    private static let maxUnits = 120

    init(settings: AppSettings, translation: TranslationService) {
        self.settings = settings
        self.translation = translation
    }

    /// 字幕条是否显示译文。
    var translating: Bool { settings.subtitleTranslate && translation.isAvailable }

    func start() {
        ticker?.cancel()
        // 定时刷新:等译文超时的句子要被跳过,即使没有新的识别结果。
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.advance()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func reset() {
        ticker?.cancel()
        ticker = nil
        captions.reset()
        liveRest = ""
        units = []
        segmenter.reset()
    }

    /// 能否走快速路径(见类型说明)。
    private var fastPath: Bool {
        !translating || (settings.translationEngine.usesSystem && translation.systemReady)
    }

    // MARK: - 输入

    func partial(_ text: String) {
        guard fastPath else {
            liveRest = text
            return
        }
        let (sentences, live) = segmenter.hypothesis(text)
        liveRest = live
        sentences.forEach { add(CaptionUnit(source: $0)) }
        advance()
    }

    /// 定稿:`text` 是这次定稿的原文,`entries` 是它在字幕记录里切好的句子。
    func final(text: String, entries: [(text: String, entryID: UUID)]) {
        if fastPath {
            segmenter.final(text).forEach { add(CaptionUnit(source: $0)) }
        } else {
            segmenter.reset()
            entries.forEach { add(CaptionUnit(source: $0.text, entryID: $0.entryID)) }
        }
        liveRest = ""
        advance()
    }

    private func add(_ unit: CaptionUnit) {
        units.append(unit)
        if unit.entryID == nil { quickTranslate(unit) }
    }

    /// 字幕记录里某句的译文有了进展(系统初稿 / AI 定稿 / 失败)。
    func entryTranslation(_ entryID: UUID, _ update: TranslationService.LineUpdate) {
        guard let i = units.lastIndex(where: { $0.entryID == entryID }) else { return }
        switch update {
        case .draft(let text):
            if units[i].translation == nil { units[i].translation = text }
        case .final(let text):
            units[i].translation = text
        case .sameLanguage:
            units[i].translation = ""
        case .failed:
            if units[i].translation == nil { units[i].translationFailed = true }
        case .streaming:
            break  // 字幕条不显示逐字生成的过程
        }
        advance()
    }

    #if DEBUG
    /// 仅调试:显示示例字幕。
    func debugShow(_ sample: [(source: String, translation: String?)], live: String) {
        units = sample.map { item in
            var unit = CaptionUnit(source: item.source)
            unit.translation = item.translation
            return unit
        }
        liveRest = live
        advance()
    }
    #endif

    // MARK: - 内部

    /// 已经说完的句子先用系统翻译出译文(只用系统翻译,足够快);不可用时等记录里的翻译结果。
    private func quickTranslate(_ unit: CaptionUnit) {
        guard translating else { return }
        let text = unit.source
        Task {
            guard let result = await translation.quickTranslate(text),
                  let i = units.firstIndex(where: { $0.id == unit.id }),
                  units[i].source == text, units[i].translation == nil else { return }
            units[i].translation = result
            advance()
        }
    }

    private func advance() {
        // 只有 AI 能翻译时等得久一些(AI 生成要几秒);有系统翻译时 4 秒还没译文就跳过这句。
        let timeout: TimeInterval = translation.systemReady && settings.translationEngine.usesSystem ? 4 : 12
        var updated = captions
        updated.update(&units, live: liveRest, translating: translating, timeout: timeout, now: Date())
        if updated != captions { captions = updated }
        // 裁掉早已滚出字幕条的旧句子(两行都已经越过它们)。
        if units.count > Self.maxUnits {
            let drop = units.count - Self.maxUnits
            units.removeFirst(drop)
            captions.dropped(drop)
        }
    }
}
