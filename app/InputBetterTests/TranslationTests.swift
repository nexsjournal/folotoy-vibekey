import XCTest
@testable import InputBetter

/// 翻译调用链逐环测试(不联网):
/// AppSettings.subtitleTranslationMethod / dictationTranslationMethod(存储与迁移)→ TranslationService.plan → BatchPlanner(按语言对分组、切块、跳过同语言)
/// → RequestGate(并发 / 间隔)→ 写回 CaptionTranscript.setTranslations;
/// 字幕条:LiveDraftPolicy(节流)→ DraftStabilizer(mask-k + 只增不改)→ RollingCaptions(暂定译文、不丢句);
/// AI 批量:Prompts.numberedUser → NumberedLines.parse。
nonisolated final class TranslationTests: XCTestCase {
    private let zhUser = ["zh-Hans-CN", "en-US"]

    // MARK: - 翻译方式

    func testMethodStorageRoundTrip() {
        let methods: [TranslationMethod] = [.system, .provider(.deepl), .provider(.baidu), .llm(model: ""), .llm(model: "qwen-plus")]
        for method in methods {
            XCTAssertEqual(TranslationMethod(storage: method.storage), method)
        }
        XCTAssertEqual(TranslationMethod.llm(model: "").storage, "llm")
        XCTAssertNil(TranslationMethod(storage: "mt.unknown"))
        XCTAssertNil(TranslationMethod(storage: "hybrid"))
        XCTAssertTrue(TranslationMethod.llm(model: "a").sameKind(as: .llm(model: "b")), "AI 不区分模型算同一类")
        XCTAssertFalse(TranslationMethod.provider(.deepl).sameKind(as: .provider(.google)))
    }

    @MainActor
    func testLegacyEngineMigration() {
        func migrated(_ key: String, _ legacy: String?) -> (AppSettings, UserDefaults) {
            let defaults = UserDefaults(suiteName: "ib-translate-\(UUID().uuidString)")!
            defaults.set(legacy, forKey: key)
            defaults.set(true, forKey: "subtitleTranslate")
            return (AppSettings(defaults: defaults), defaults)
        }
        XCTAssertEqual(migrated("translationEngine", "hybrid").0.subtitleTranslationMethod, .system, "混合模式已去掉,迁移为系统翻译")
        XCTAssertEqual(migrated("translationEngine", "llm").0.dictationTranslationMethod, .llm(model: ""))
        let (shared, sharedDefaults) = migrated("translationMethod", "mt.deepl")
        XCTAssertEqual(shared.subtitleTranslationMethod, .provider(.deepl), "上一版共用的方式作为两个场景的初始值")
        XCTAssertEqual(shared.dictationTranslationMethod, .provider(.deepl))
        XCTAssertNil(sharedDefaults.object(forKey: "translationMethod"), "旧键清除")
        XCTAssertNil(sharedDefaults.object(forKey: "subtitleTranslate"), "旧的全局翻译开关清除(每场字幕默认不翻译)")
        // 两个场景分开保存。
        shared.dictationTranslationMethod = .llm(model: "qwen-plus")
        let reloaded = AppSettings(defaults: sharedDefaults)
        XCTAssertEqual(reloaded.subtitleTranslationMethod, .provider(.deepl))
        XCTAssertEqual(reloaded.dictationTranslationMethod, .llm(model: "qwen-plus"))
        XCTAssertEqual(migrated("x", nil).0.subtitleTranslationMethod, .system, "全新安装默认系统翻译")
    }

    @MainActor
    func testLegacyFontSizeSplitsIntoSourceAndTranslation() {
        let defaults = UserDefaults(suiteName: "ib-font-\(UUID().uuidString)")!
        defaults.set(24.0, forKey: "subtitleFontSize")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.subtitleSourceFontSize, 18, "旧的单一字号按比例换算成原文字号")
        XCTAssertEqual(settings.subtitleTranslationFontSize, 20)
        XCTAssertNil(defaults.object(forKey: "subtitleFontSize"))
        XCTAssertEqual(AppSettings(defaults: defaults).subtitleTranslationFontSize, 20, "换算结果已保存")
        XCTAssertEqual(AppSettings(defaults: UserDefaults(suiteName: "ib-font-\(UUID().uuidString)")!).subtitleTranslationLines, 3, "默认译文 3 行")
    }

    func testSimplifiedChineseIsNormalized() {
        XCTAssertEqual(TranslationService.normalized("修飾符和屬性", target: .zhHans), "修饰符和属性", "系统翻译混出的繁体字转成简体")
        XCTAssertEqual(TranslationService.normalized("修飾符", target: .zhHant), "修飾符", "目标是繁体时不转换")
    }

    func testResolvedTargetIsNeverAuto() {
        let en = Locale.Language(identifier: "en"), zh = Locale.Language(identifier: "zh-Hans")
        XCTAssertEqual(TargetLanguage.auto.resolvedTarget(source: en, preferred: zhUser), .zhHans)
        XCTAssertEqual(TargetLanguage.auto.resolvedTarget(source: zh, preferred: zhUser), .en)
        XCTAssertEqual(TargetLanguage.auto.resolvedTarget(source: nil, preferred: zhUser), .zhHans, "识别不出时译成主语言")
        XCTAssertEqual(TargetLanguage.ja.resolvedTarget(source: en, preferred: zhUser), .ja)
    }

    // MARK: - 分块

    func testPlannerGroupsByResolvedTargetAndSkipsSameLanguage() {
        let items = ["Hello there my friend.", "今天天气很好，我们出去走走吧。", "How are you doing today?", "   "].map {
            BatchPlanner.Item(id: UUID(), text: $0)
        }
        let plan = BatchPlanner.plan(items, target: .auto, limits: .llm, groupBySource: false, preferred: zhUser, detect: LanguageDetector.detect)
        XCTAssertEqual(plan.chunks.count, 2, "自动目标:英文 → 中文、中文 → 英文,分成两组")
        XCTAssertEqual(plan.chunks[0].target, .zhHans)
        XCTAssertEqual(plan.chunks[0].items.map(\.id), [items[0].id, items[2].id], "保持原来的顺序")
        XCTAssertEqual(plan.chunks[1].target, .en)
        XCTAssertEqual(plan.skipped, [items[3].id], "空句不翻译")

        let fixed = BatchPlanner.plan(items, target: .zhHans, limits: .llm, groupBySource: false, preferred: zhUser, detect: LanguageDetector.detect)
        XCTAssertTrue(fixed.skipped.contains(items[1].id), "原文已是目标语言,不发请求")
        XCTAssertEqual(fixed.chunks.flatMap(\.items).count, 2)
    }

    func testPlannerSplitsByLimits() {
        let items = (0..<7).map { BatchPlanner.Item(id: UUID(), text: "Sentence number \($0) here.") }
        let limits = BatchLimits(maxItems: 3, maxLength: 10_000, maxConcurrent: 1, minInterval: 0)
        XCTAssertEqual(BatchPlanner.split(items, limits: limits).map(\.count), [3, 3, 1])
        let byLength = BatchLimits(maxItems: 100, maxLength: 50, maxConcurrent: 1, minInterval: 0)
        XCTAssertEqual(BatchPlanner.split(items, limits: byLength).map(\.count), [2, 2, 2, 1])
        // 百度按 UTF-8 字节算:每个汉字 3 字节。
        let chinese = (0..<3).map { _ in BatchPlanner.Item(id: UUID(), text: "你好世界") }  // 12 字节
        let bytes = BatchLimits(maxItems: 50, maxLength: 24, countsUTF8Bytes: true, maxConcurrent: 1, minInterval: 0)
        XCTAssertEqual(BatchPlanner.split(chinese, limits: bytes).map(\.count), [2, 1])
    }

    func testSystemPlanGroupsBySource() {
        let items = ["Good morning everyone, welcome.", "Bonjour à tous et bienvenue ici."].map { BatchPlanner.Item(id: UUID(), text: $0) }
        let plan = BatchPlanner.plan(items, target: .zhHans, limits: .system, groupBySource: true, preferred: zhUser, detect: LanguageDetector.detect)
        XCTAssertEqual(plan.chunks.count, 2, "系统翻译按语言对建会话,源语言不同要分开")
        XCTAssertNotNil(plan.chunks[0].source)
    }

    // MARK: - AI 批量格式

    func testNumberedLines() {
        XCTAssertEqual(NumberedLines.format(["a", "b\nc"]), "[1] a\n[2] b c")
        XCTAssertEqual(NumberedLines.parse("Here you go:\n[1] 你好\n[2] 世界\n", count: 2), ["你好", "世界"])
        XCTAssertEqual(NumberedLines.parse("[1] 第一句\n继续\n[2] 第二句", count: 2), ["第一句 继续", "第二句"], "续行并入上一条")
        XCTAssertNil(NumberedLines.parse("[1] 只有一句", count: 2), "数量不对返回 nil,调用方逐句重试")
        XCTAssertNil(NumberedLines.parse("[1] a\n[2] b\n[3] c", count: 2))
        let user = Prompts.numberedUser(["Hello", "World"], context: [(source: "Hi", translation: "嗨")])
        XCTAssertTrue(user.contains("PREVIOUS:\nHi\n  → 嗨"))
        XCTAssertTrue(user.hasSuffix("LINES:\n[1] Hello\n[2] World"))
    }

    // MARK: - 边说边译

    func testDraftStabilizerMasksTailAndOnlyGrows() {
        var stabilizer = DraftStabilizer()
        XCTAssertEqual(stabilizer.update("所以应用需要"), "所以应", "中文遮住最后 3 个字")
        XCTAssertEqual(stabilizer.update("所以应用需要一个状态"), "所以应用需要一")
        XCTAssertEqual(stabilizer.update("因此这个应用需要"), "所以应用需要一", "开头变了:已显示的不改写")
        XCTAssertEqual(stabilizer.update("所以应用需要一个状态变量来跟踪"), "所以应用需要一个状态变量", "新译文以已显示内容开头时继续追加")

        var english = DraftStabilizer()
        XCTAssertEqual(english.update("So the app will need"), "So the app", "英文遮住最后 2 个词")
        XCTAssertEqual(english.update("So the app will need a piece of state"), "So the app will need a piece")
    }

    func testDraftStabilizerRevisesWhenNewWordingIsStable() {
        var stabilizer = DraftStabilizer()
        stabilizer.update("今天我想带您了解")  // 显示 "今天我想带"
        XCTAssertEqual(stabilizer.update("今天，我想向您介绍状态"), "今天我想带", "措辞第一次变化:先不改写")
        XCTAssertEqual(stabilizer.update("今天，我想向您介绍状态是如何工作"), "今天，我想向您介",
                       "新措辞连续两次一致且更长:改写成一致的部分,不会一直冻住")
    }

    // MARK: - 边说边译的片段

    func testDraftSegmentsCutAtPunctuationOrLength() {
        let text = "There are a few different places where this will come up, like keeping track of when a sheet is shown after tapping a button or when an alert"
        let segments = DraftSegments.split(text)
        XCTAssertEqual(segments.first?.text, "There are a few different places where this will come up,", "在逗号处切")
        XCTAssertTrue(segments.dropFirst().allSatisfy { $0.tokens <= 14 }, "没有标点时满 14 个词硬切")
        XCTAssertEqual(DraftSegments.split("Today I want to walk you."), [], "不在文字末尾切(末尾标点还会变)")
        // 只在末尾增长时,已切出的片段不变(每段只翻译一次)。
        let longer = DraftSegments.split(text + " needs to be displayed on the wishlist tab")
        XCTAssertEqual(Array(longer.prefix(segments.count)), segments)
        let consumed = segments.reduce(0) { $0 + $1.tokens }
        XCTAssertTrue(DraftSegments.dropTokens(consumed, from: text + " needs").hasSuffix("an alert needs"))
        XCTAssertEqual(DraftSegments.split("你好，今天我们来聊一聊状态管理，这是一个很重要的话题")
                        .first?.text, "你好，今天我们来聊一聊状态管理，", "中文按字计长度,太短的片段不切")
    }

    func testTranslationLinesAreOneParagraphPerSentence() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [unit("First one.", "第一句。", now: now), unit("Second one in progress.", draft: "第二句", now: now)]
        captions.update(&units, live: "and", liveDraft: "而且", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationLines.map(\.text), ["第一句。", "第二句", "而且"], "每句单独成段,正在说的半句是最后一段")
        XCTAssertEqual(captions.translationLines.map(\.provisional), [false, true, true])
        let firstID = captions.translationLines[0].id
        units[1].translation = "第二句译好了。"
        captions.update(&units, live: "", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationLines.first?.id, firstID, "后面的句子变化时,前面已读的句子不变(位置稳定)")
        XCTAssertEqual(captions.translationLines.last?.text, "第二句译好了。")

        var many = (0..<60).map { unit("Sentence \($0).", "第\($0)句。", now: now) }
        captions.reset()
        captions.update(&many, live: "", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationLines.count, RollingCaptions.maxTranslationLines, "旧句子按整句滚出")
        XCTAssertEqual(captions.translationLines.last?.text, "第59句。")
    }

    func testLateTranslationReplacesFallback() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [unit("Slow sentence from an online service.", now: now.addingTimeInterval(-20))]
        captions.update(&units, live: "", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationLines.first?.text, "Slow sentence from an online service.", "超时先用原文顶替")
        XCTAssertTrue(captions.translationLines.first?.provisional == true)
        units[0].translation = "来自在线服务的慢句子。"
        captions.update(&units, live: "", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationLines.first?.text, "来自在线服务的慢句子。", "迟到的整句译文替换顶替内容(每句独立成段,不影响别的句子)")
        XCTAssertTrue(captions.translationLines.first?.provisional == false)
    }

    func testSameLanguageSentencesAreKeptAsSourceRows() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [unit("Hello there.", "你好。", now: now), unit("这句本来就是中文。", "", now: now), unit("Next one.", "下一句。", now: now)]
        captions.update(&units, live: "", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationLines.map(\.text), ["你好。", "这句本来就是中文。", "下一句。"], "同语言的句子以原文行给出,顺序不变")
        XCTAssertEqual(captions.translationLines.map(\.sameLanguage), [false, true, false])
        XCTAssertEqual(captions.translation, "你好。下一句。", "连续文字里仍不含同语言句子")
    }

    func testHeldDraftCoversUnitsWaitingForTranslation() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [CaptionUnit(source: "First sentence finalized just now.", createdAt: now)]
        captions.update(&units, live: "", heldDraft: "第一句暂定", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationLive, "第一句暂定", "定稿的新句子还没整句译文:先顶上之前的暂定译文,不出现空档")
        XCTAssertFalse(captions.translationWaiting)
        XCTAssertTrue(captions.unitsWaiting)
        units[0].translation = "第一句已定稿。"
        captions.update(&units, live: "", heldDraft: "第一句暂定", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translation, "第一句已定稿。")
        XCTAssertFalse(captions.unitsWaiting, "整句译文到了:CaptionFeed 据此丢掉 heldDraft")
    }

    func testLiveDraftPolicyThrottles() {
        let now = Date()
        XCTAssertFalse(LiveDraftPolicy.shouldRequest("Hello", method: .system, last: nil, now: now), "太短不翻")
        XCTAssertTrue(LiveDraftPolicy.shouldRequest("Hello there", method: .system, last: nil, now: now))
        XCTAssertFalse(LiveDraftPolicy.shouldRequest("Hello there friend", method: .system, last: ("Hello there", now), now: now), "间隔太短")
        XCTAssertTrue(LiveDraftPolicy.shouldRequest("Hello there friend", method: .system, last: ("Hello there", now.addingTimeInterval(-0.5)), now: now))
        let old = now.addingTimeInterval(-2)
        XCTAssertFalse(LiveDraftPolicy.shouldRequest("one two three four", method: .provider(.deepl), last: ("one two three", old), now: now),
                       "在线服务要多出 3 个词才重翻(省额度)")
        XCTAssertTrue(LiveDraftPolicy.shouldRequest("one two three four five six", method: .provider(.deepl), last: ("one two three", old), now: now))
        XCTAssertFalse(LiveDraftPolicy.shouldRequest("one two three four five six", method: .llm(model: ""), last: nil, now: now), "AI 不做边说边译")
    }

    // MARK: - 字幕条

    private func unit(_ text: String, _ translation: String? = nil, draft: String? = nil, now: Date) -> CaptionUnit {
        var unit = CaptionUnit(source: text, createdAt: now)
        unit.translation = translation
        unit.draft = draft
        return unit
    }

    func testRollingShowsDraftsAndLiveDraftDimmed() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [unit("First sentence is complete here.", "第一句已经完整。", now: now),
                     unit("Second sentence is still translating.", draft: "第二句还在", now: now)]
        captions.update(&units, live: "and the speaker", liveDraft: "而讲者", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationFinal, "第一句已经完整。")
        XCTAssertEqual(captions.translationLive, "第二句还在而讲者", "还没定下来的句子先显示暂定译文,末尾接上正在说的半句")
        XCTAssertFalse(captions.translationWaiting)

        units[1].translation = "第二句还在翻译中。"
        captions.update(&units, live: "", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translationFinal, "第一句已经完整。第二句还在翻译中。", "整句译文到达后替换暂定译文")
    }

    func testRollingWaitsOnlyWhenNothingToShow() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [unit("Nothing yet for this sentence.", now: now), unit("Later one.", "后面一句。", now: now)]
        captions.update(&units, live: "", liveDraft: "暂定", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translation, "", "前一句什么都没有时,后面的等它(保持顺序)")
        XCTAssertTrue(captions.translationWaiting, "这时才显示「翻译中…」")

        var sameLanguage = [unit("这句已经是中文了。", "", now: now)]
        captions.reset()
        captions.update(&sameLanguage, live: "", translating: true, timeout: 8, now: now)
        XCTAssertFalse(captions.translationWaiting, "原文已是目标语言:不显示「翻译中…」")
    }

    func testRestartTranslationHidesOldTranslations() {
        let now = Date()
        var captions = RollingCaptions()
        var units = [unit("Old one.", "旧的。", now: now), unit("Latest.", "最新。", now: now)]
        captions.update(&units, live: "", translating: true, timeout: 8, now: now)
        captions.restartTranslation(from: 1)
        units[1].shownTranslation = nil
        units[1].translation = "Le plus récent."
        captions.update(&units, live: "", translating: true, timeout: 8, now: now)
        XCTAssertEqual(captions.translation, "Le plus récent.", "换语言后只显示最新一句的新译文")
    }

    // MARK: - 记录

    func testTranscriptBatchWrite() {
        var transcript = CaptionTranscript(appName: "A")
        let a = CaptionTranscript.Entry(text: "a"), b = CaptionTranscript.Entry(text: "b"), c = CaptionTranscript.Entry(text: "c")
        [a, b, c].forEach { transcript.append($0) }
        transcript.setTranslations([a.id: "甲", b.id: ""], failed: [c.id], target: .zhHans)
        XCTAssertEqual(transcript.entries.map(\.translation), ["甲", "", nil])
        XCTAssertEqual(transcript.entries[0].translationTarget, .zhHans)
        XCTAssertTrue(transcript.entries[2].translationFailed)
        transcript.setTranslations([a.id: "甲（润色）"], target: .zhHans, polished: true)
        XCTAssertTrue(transcript.entries[0].translationPolished)
        transcript.setTranslation("A", for: a.id, target: .en)
        XCTAssertFalse(transcript.entries[0].translationPolished, "重新翻译后润色标记清除")
    }

    // MARK: - 闸门

    func testRequestGateLimitsConcurrency() async throws {
        let gate = RequestGate(limits: BatchLimits(maxItems: 1, maxLength: 1, maxConcurrent: 1, minInterval: 0))
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await gate.run {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 1, "并发上限 1 时请求依次执行")
    }

    func testRequestGateHonorsInterval() async throws {
        let gate = RequestGate(limits: BatchLimits(maxItems: 1, maxLength: 1, maxConcurrent: 4, minInterval: 0.15))
        let start = Date()
        for _ in 0..<3 { try await gate.run { } }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.29, "两次请求之间至少间隔 minInterval(QPS 限制)")
    }

    func testRequestGateCancellation() async {
        let gate = RequestGate(limits: BatchLimits(maxItems: 1, maxLength: 1, maxConcurrent: 1, minInterval: 5))
        try? await gate.run { }
        let task = Task { try await gate.run { } }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get(), "等待中被取消立即结束")
    }

    func testChatModelFilter() {
        XCTAssertEqual(LLMModelCatalog.chatCandidates(["gpt-4o-mini", "text-embedding-3-small", "whisper-1", "tts-1", "deepseek-chat"]),
                       ["gpt-4o-mini", "deepseek-chat"])
    }
}

private actor Counter {
    private var active = 0
    private(set) var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}
