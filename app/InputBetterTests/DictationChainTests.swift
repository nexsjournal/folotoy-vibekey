import AppKit
import XCTest
@testable import InputBetter

/// 链:DictationController.start → DictationEngineSource.dictationEngine → ASREngine.makeSession
///  → stop → ASRSession.finish → DictationPostProcessing.process → TextInserting.insert → succeed / fail。
/// 依赖全部换成假实现,逐环验证取消、后处理警告和按键状态。
nonisolated final class DictationChainTests: XCTestCase {
    /// 一套假依赖和用它们组装的控制器。
    @MainActor private struct Rig {
        let c: DictationController
        let engine: FakeDictationEngine
        let post: FakePostProcessor
        let inserter: FakeInserter
    }

    @MainActor private func makeRig(transcript: String = "你好世界") -> Rig {
        let defaults = UserDefaults(suiteName: "ib-dictation-\(UUID().uuidString)")!
        let credentials = CredentialStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ib-dictation-\(UUID().uuidString).json"))
        let settings = AppSettings(defaults: defaults, credentials: credentials)
        settings.soundEffects = false
        let engine = FakeDictationEngine(transcript: transcript)
        let post = FakePostProcessor()
        let inserter = FakeInserter()
        let c = DictationController(settings: settings, engines: FakeEngineSource(engine: engine), postProcessor: post,
                                    inserter: inserter, sounds: SoundEffects(settings: settings),
                                    makeSource: { FakeAudioSource() })
        return Rig(c: c, engine: engine, post: post, inserter: inserter)
    }

    /// 轮询等待条件成立(主线程上的状态由各个 Task 推进)。
    @MainActor private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// 免提开始一次录音并等到会话就绪。
    @MainActor private func startRecording(_ c: DictationController, mode: DictationController.Mode = .dictate) async {
        c.toggle(mode: mode)
        await waitUntil { c.phase == .recording }
        // 录音时长超过误触阈值(0.5 秒),空结果时才会提示"没有听到声音"。
    }

    @MainActor func testHappyPathInsertsText() async {
        let rig = makeRig()
        let c = rig.c
        await startRecording(c)
        XCTAssertEqual(c.phase, .recording)
        c.stop()
        await waitUntil { if case .done = c.phase { true } else { false } }
        XCTAssertEqual(c.phase, .done(.typed))
        XCTAssertEqual(rig.inserter.inserted, ["你好世界"])
        XCTAssertEqual(c.lastText, "你好世界")
    }

    /// 处理中(翻译 / 润色)点 ✕:不再粘贴,也不报错。
    @MainActor func testCancelDuringPostProcessDoesNotInsert() async {
        let rig = makeRig()
        let c = rig.c
        rig.post.delay = .seconds(5)
        await startRecording(c, mode: .translate)
        c.stop()
        await waitUntil { c.phase == .processing(.translating) }
        XCTAssertEqual(c.phase, .processing(.translating))
        c.cancel()
        XCTAssertEqual(c.phase, .idle)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.inserter.inserted, [], "取消后不能再把文字输入进去")
        XCTAssertEqual(c.phase, .idle, "取消后流程不能再改状态")
        XCTAssertNil(c.lastText)
    }

    /// 模型加载中松开、再点 ✕:不报 engineNotReady,也不显示 CancellationError 的系统文案。
    @MainActor func testCancelWhileLoadingModelDoesNotFail() async {
        let rig = makeRig()
        let c = rig.c
        rig.engine.loadsUntilCancelled = true
        c.toggle()
        XCTAssertEqual(c.phase, .starting)
        c.stop()
        await waitUntil { c.phase == .processing(.loadingModel) }
        XCTAssertEqual(c.phase, .processing(.loadingModel))
        c.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(rig.inserter.inserted, [])
    }

    /// 还在加载模型(录音中)就点 ✕:会话任务被取消抛出的错误不能变成失败提示。
    @MainActor func testCancelWhileStartingDoesNotFail() async {
        let rig = makeRig()
        let c = rig.c
        rig.engine.loadsUntilCancelled = true
        c.toggle()
        c.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.phase, .idle)
    }

    /// 翻译失败退回原文:输入原文,结果是警告(不是绿色「已输入」)。
    @MainActor func testTranslationFallbackIsWarning() async {
        let rig = makeRig()
        let c = rig.c
        rig.post.result = { PostProcessed(text: $0, warning: .untranslated("请求超时")) }
        await startRecording(c, mode: .translate)
        c.stop()
        await waitUntil { if case .done = c.phase { true } else { false } }
        XCTAssertEqual(c.phase, .done(.typedUntranslated("请求超时")))
        XCTAssertEqual(rig.inserter.inserted, ["你好世界"])
        XCTAssertTrue(DictationResult.typedUntranslated("x").isWarning)
        XCTAssertFalse(DictationResult.typed.isWarning)
    }

    @MainActor func testPolishFallbackIsWarning() {
        XCTAssertEqual(DictationResult.typed(warning: .unpolished("401")), .typedUnpolished("401"))
        XCTAssertEqual(DictationResult.typed(warning: nil), .typed)
        XCTAssertTrue(DictationResult.typedUnpolished("401").title.contains("401"), "标题里带原因")
    }

    /// 翻译方式不可用:失败原因来自 unavailableReason。
    @MainActor func testTranslationUnavailableCarriesReason() {
        let rig = makeRig()
        let c = rig.c
        rig.post.unavailableReason = "还没有配置 AI 服务"
        c.toggle(mode: .translate)
        XCTAssertEqual(c.phase, .failed(.translationUnavailable(reason: "还没有配置 AI 服务")))
        XCTAssertTrue(DictationFailure.translationUnavailable(reason: "还没有配置 AI 服务").title.contains("还没有配置 AI 服务"))
    }

    /// 处理中又按了一次触发键:不开始录音,但按键状态要复位,处理完后下一次按下能正常开始。
    @MainActor func testPressWhileBusyDoesNotSwallowNextPress() async {
        let rig = makeRig()
        let c = rig.c
        rig.post.delay = .milliseconds(400)
        await startRecording(c, mode: .translate)
        c.stop()
        await waitUntil { c.phase == .processing(.translating) }
        c.pressDown(mode: .dictate)
        c.pressUp()
        XCTAssertEqual(c.phase, .processing(.translating), "处理中不开始新的录音")
        await waitUntil { if case .done = c.phase { true } else { false } }
        c.pressDown(mode: .dictate)
        XCTAssertEqual(c.phase, .starting, "下一次按下应当开始录音,而不是被当成「结束」吞掉")
        c.cancel()
    }

    /// 识别结果为空且会话报告了错误(如云端超时):显示错误原因。
    @MainActor func testStreamErrorShownWhenTranscriptEmpty() async {
        let rig = makeRig(transcript: "")
        let c = rig.c
        rig.engine.failureOnFinish = "连接 Test 超时，请检查网络"
        await startRecording(c)
        c.stop()
        await waitUntil { if case .failed = c.phase { true } else { false } }
        XCTAssertEqual(c.phase, .failed(.other("连接 Test 超时，请检查网络")), "结束时才报告的错误也要被处理到")
    }
}

/// 链:DictationPostProcessor.translationUnavailableReason → TranslationService.unavailableReason;
/// step(for:) → AppSettings.polishEnabled / TextProcessor.isAvailable;process 失败 → 退回原文 + 警告。
nonisolated final class DictationPostProcessorTests: XCTestCase {
    @MainActor private func make() -> (DictationPostProcessor, AppSettings) {
        let defaults = UserDefaults(suiteName: "ib-post-\(UUID().uuidString)")!
        let credentials = CredentialStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("ib-post-\(UUID().uuidString).json"))
        let settings = AppSettings(defaults: defaults, credentials: credentials)
        let processor = TextProcessor(settings: settings)
        let translation = TranslationService(settings: settings, processor: processor,
                                             providers: MachineTranslationStore(defaults: defaults, credentials: credentials))
        return (DictationPostProcessor(settings: settings, processor: processor, translation: translation), settings)
    }

    @MainActor func testStepsAndAvailability() {
        let (post, settings) = make()
        settings.dictationTranslationMethod = .llm(model: "")
        settings.llmBaseURL = ""
        XCTAssertNotNil(post.translationUnavailableReason, "没配置 AI 服务时 AI 翻译不可用,并给出原因")
        XCTAssertEqual(post.step(for: .translate), .translating)
        settings.polishEnabled = true
        XCTAssertNil(post.step(for: .dictate), "AI 服务没配置就不润色")
        settings.llmBaseURL = "http://127.0.0.1:9/v1"
        settings.llmModel = "test-model"
        XCTAssertNil(post.translationUnavailableReason)
        XCTAssertEqual(post.step(for: .dictate), .polishing)
        settings.polishEnabled = false
        XCTAssertNil(post.step(for: .dictate))
    }

    /// 服务连不上:退回原文并带上对应的警告。
    @MainActor func testFailureFallsBackToOriginalWithWarning() async {
        let (post, settings) = make()
        settings.llmBaseURL = "http://127.0.0.1:9/v1"  // 本机没有服务监听的端口,连接立即被拒
        settings.llmModel = "test-model"
        settings.polishEnabled = true
        settings.dictationTranslationMethod = .llm(model: "")
        let polished = await post.process("原文", mode: .dictate)
        XCTAssertEqual(polished.text, "原文")
        guard case .unpolished(let reason)? = polished.warning else { return XCTFail("润色失败应当带警告") }
        XCTAssertFalse(reason.isEmpty)
        let translated = await post.process("原文", mode: .translate)
        XCTAssertEqual(translated.text, "原文")
        guard case .untranslated? = translated.warning else { return XCTFail("翻译失败应当带警告") }
        settings.polishEnabled = false
        let plain = await post.process("原文", mode: .dictate)
        XCTAssertEqual(plain, PostProcessed(text: "原文", warning: nil), "不需要后处理时原样返回")
    }
}

// MARK: - 假实现

@MainActor
private final class FakeEngineSource: DictationEngineSource {
    let engine: ASREngine?
    init(engine: ASREngine?) { self.engine = engine }
    func dictationEngine(for modelID: String) -> ASREngine? { engine }
}

/// 假识别引擎:可以模拟"一直在加载模型,直到被取消"。
@MainActor
private final class FakeDictationEngine: ASREngine {
    let transcript: String
    var loadsUntilCancelled = false
    var failureOnFinish: String?
    init(transcript: String) { self.transcript = transcript }

    var isLoaded: Bool { true }
    func prepare() async throws {}
    func unload() {}

    func makeSession(_ options: ASROptions) async throws -> ASRSession {
        if loadsUntilCancelled {
            while true { try await Task.sleep(for: .milliseconds(10)) }  // 取消时抛出 CancellationError
        }
        return FakeASRSession(transcript: transcript, failureOnFinish: failureOnFinish)
    }
}

/// 假识别会话:结束时(可选)先发一条错误事件,再关闭事件流并返回固定文本。
private nonisolated final class FakeASRSession: ASRSession, @unchecked Sendable {
    let events: AsyncStream<TranscriptEvent>
    private let sink: AsyncStream<TranscriptEvent>.Continuation
    private let transcript: String
    private let failureOnFinish: String?

    init(transcript: String, failureOnFinish: String?) {
        (events, sink) = AsyncStream.makeStream(of: TranscriptEvent.self)
        self.transcript = transcript
        self.failureOnFinish = failureOnFinish
    }

    func feed(_ samples: [Float]) {}

    func finish() async -> String {
        if let failureOnFinish { sink.yield(.failure(failureOnFinish)) }
        sink.finish()
        return transcript
    }

    func cancel() { sink.finish() }
}

@MainActor
private final class FakePostProcessor: DictationPostProcessing {
    var unavailableReason: String?
    var delay: Duration = .zero
    var result: ((String) -> PostProcessed)?

    var translationUnavailableReason: String? { unavailableReason }

    func step(for mode: DictationController.Mode) -> ProcessingStep? { mode == .translate ? .translating : nil }

    func process(_ text: String, mode: DictationController.Mode) async -> PostProcessed {
        if delay > .zero { try? await Task.sleep(for: delay) }
        return result?(text) ?? PostProcessed(text: text, warning: nil)
    }
}

@MainActor
private final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    func insert(_ text: String, target: NSRunningApplication?) async -> TextInserter.Outcome {
        inserted.append(text)
        return .pasted
    }
}

private nonisolated final class FakeAudioSource: AudioSource {
    var onSamples: (@Sendable ([Float]) -> Void)?
    func start() throws {}
    func stop() {}
}
