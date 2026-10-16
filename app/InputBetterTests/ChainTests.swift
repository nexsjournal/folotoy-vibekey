import AVFoundation
import XCTest
@testable import InputBetter

/// 沿 docs/architecture.md 的调用链逐环测试:每个用例只验证链上一个函数的输入输出。
nonisolated final class AudioChainTests: XCTestCase {
    /// 链:MicSource / AppAudioTap → AudioConverter.convert → 16 kHz 单声道。
    func testConverterDownsamplesStereoToMono16k() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = AVAudioFrameCount(24_000)  // 0.5 秒
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = 0.5 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
        }
        // 连续送入多块(模拟实时流):转换器只有固定的内部延迟(< 70 ms),不能每块都丢样本。
        let converter = AudioConverter()
        var total: [Float] = []
        for _ in 0..<4 { total += converter.convert(buffer) }
        let afterFour = total.count
        for _ in 0..<4 { total += converter.convert(buffer) }
        let missingAfterFour = 32_000 - afterFour
        let missingAfterEight = 64_000 - total.count
        XCTAssertLessThan(missingAfterFour, 1_120, "固定延迟应小于 70 ms")
        XCTAssertLessThanOrEqual(missingAfterEight, missingAfterFour + 50, "缺少的样本不能随块数增长(否则是在丢数据)")
        XCTAssertGreaterThan(total.map(abs).max() ?? 0, 0.3)
    }

    /// 链:AppleSpeechSession.feed → AudioFormats.buffer → AudioConverter.convertBuffer。
    func testBufferFromSamplesAndPassThrough() {
        let buffer = AudioFormats.buffer(from: [0.1, 0.2, 0.3])!
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertTrue(AudioConverter().convertBuffer(buffer) === buffer, "目标格式相同时应原样返回")
        XCTAssertNil(AudioFormats.buffer(from: []))
    }

    /// 链:onSamples → AudioFormats.level → AudioFormats.smoothLevel。
    func testLevelAndSmoothing() {
        XCTAssertEqual(AudioFormats.level(of: [Float](repeating: 0, count: 100)), 0)
        XCTAssertGreaterThan(AudioFormats.level(of: [Float](repeating: 0.5, count: 100)), 0.8)
        XCTAssertEqual(AudioFormats.smoothLevel(0.2, toward: 0.9), 0.9, "上升立即跟随")
        XCTAssertEqual(AudioFormats.smoothLevel(1.0, toward: 0, decay: 0.8), 0.8, accuracy: 1e-6)
    }
}

/// 链:SegmentedSession.feed → VoiceActivityDetector → SegmentDecoder.decode → finish。
nonisolated final class SegmentedSessionChainTests: XCTestCase {
    /// 记录调用次数的假解码器。
    final class FakeDecoder: SegmentDecoder, @unchecked Sendable {
        let partialInterval = 0.0
        let maxWholeSeconds = 600.0
        let prefersWholeDictation: Bool
        private let lock = NSLock()
        private var lengths: [Int] = []
        init(whole: Bool) { prefersWholeDictation = whole }
        var calls: [Int] { lock.withLock { lengths } }
        func decode(_ samples: [Float], options: ASROptions) async -> String {
            lock.withLock { lengths.append(samples.count) }
            return "句子\(samples.count / 16_000)"
        }
    }

    private func speech() throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "speech_zh", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return AudioConverter().convert(buffer)
    }

    private func run(_ samples: [Float], decoder: FakeDecoder, purpose: ASRPurpose) async -> String {
        let session = SegmentedSession(decoder: decoder, options: ASROptions(purpose: purpose, language: .zh, vocabulary: []))
        var i = 0
        while i < samples.count {
            session.feed(Array(samples[i..<min(i + 1_600, samples.count)]))
            i += 1_600
        }
        return await session.finish()
    }

    func testSilenceProducesNothingAndNeverDecodesFinal() async {
        let decoder = FakeDecoder(whole: true)
        let text = await run([Float](repeating: 0, count: 16_000 * 3), decoder: decoder, purpose: .dictation)
        XCTAssertEqual(text, "")
        XCTAssertTrue(decoder.calls.isEmpty, "没有语音时不应调用解码器(Whisper 会对静音幻听)")
    }

    func testDictationReturnsDecodedSpeech() async throws {
        let decoder = FakeDecoder(whole: true)
        let text = await run(try speech(), decoder: decoder, purpose: .dictation)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(decoder.calls.isEmpty)
        // 整段模式下,结束时解码的片段覆盖全部语音(约 8 秒),不应只有一小段。
        XCTAssertGreaterThan(decoder.calls.max() ?? 0, 16_000 * 6)
    }

    func testSubtitlesCommitSegments() async throws {
        let decoder = FakeDecoder(whole: false)
        let text = await run(try speech(), decoder: decoder, purpose: .subtitles)
        XCTAssertTrue(text.hasPrefix("句子"), "字幕模式按句定稿后拼接:\(text)")
    }
}

/// 链:DeviceBridge.sync → DeviceStateMapper → DeviceLink.send*。
nonisolated final class DeviceStateMapperTests: XCTestCase {
    @MainActor func testCaptionsPageWheneverCaptionsRun() {
        let sub = DeviceStateMapper.state(phase: .idle, dictationMode: .dictate, deviceMode: .sub, subtitlesRunning: true, subtitleApp: "Chrome")
        XCTAssertEqual(sub, .init(ui: .sub, mode: .sub, msg: "Chrome"))
        // 听写模式下字幕在运行:同样显示字幕页(mode 如实为 dict),按键仍是听写模式的含义。
        let live = DeviceStateMapper.state(phase: .idle, dictationMode: .dictate, deviceMode: .dict, subtitlesRunning: true, subtitleApp: "Chrome")
        XCTAssertEqual(live, .init(ui: .sub, mode: .dict, msg: "Chrome"))
        let dictHints = DeviceStateMapper.keyHints(state: .sub, deviceMode: .dict, handsFree: false, canTranslate: true, up: .enter, down: .escape)
        XCTAssertEqual(dictHints.ok, .mic, "听写模式下字幕页的 OK 仍是说话")
        XCTAssertEqual(dictHints.up, KeyAction.enter.deviceIcon)
        // 听写优先:字幕运行中开始听写,设备显示录音页。
        let rec = DeviceStateMapper.state(phase: .recording, dictationMode: .dictate, deviceMode: .sub, subtitlesRunning: true, subtitleApp: "Chrome")
        XCTAssertEqual(rec.ui, .rec)
    }

    @MainActor func testRecordingTranslateMode() {
        let s = DeviceStateMapper.state(phase: .recording, dictationMode: .translate, deviceMode: .dict, subtitlesRunning: false, subtitleApp: "")
        XCTAssertEqual(s, .init(ui: .rec, mode: .tr, msg: ""))
    }

    @MainActor func testDoneAndFailedMessagesAreASCII() {
        XCTAssertEqual(DeviceStateMapper.state(phase: .done(.typed), dictationMode: .dictate, deviceMode: .dict, subtitlesRunning: false, subtitleApp: "").msg, "TYPED")
        XCTAssertEqual(DeviceStateMapper.state(phase: .done(.copied(.windowChanged)), dictationMode: .dictate, deviceMode: .dict, subtitlesRunning: false, subtitleApp: "").msg, "COPIED")
        XCTAssertEqual(DeviceStateMapper.state(phase: .failed(.noSpeech), dictationMode: .dictate, deviceMode: .dict, subtitlesRunning: false, subtitleApp: "").msg, "NO SPEECH")
        XCTAssertEqual(DeviceStateMapper.asciiError(.noModel), "NO MODEL")
    }

    @MainActor func testKeyHints() {
        XCTAssertEqual(DeviceStateMapper.keyHints(state: .idle, deviceMode: .dict, handsFree: false, canTranslate: false, up: .enter, down: .escape),
                       .init(ok: .mic, up: .enter, down: .esc))
        XCTAssertEqual(DeviceStateMapper.keyHints(state: .rec, deviceMode: .dict, handsFree: true, canTranslate: false, up: .enter, down: .escape).ok, .stop)
        XCTAssertEqual(DeviceStateMapper.keyHints(state: .sub, deviceMode: .sub, handsFree: false, canTranslate: true, up: .enter, down: .escape).up, .translate)
        XCTAssertNil(DeviceStateMapper.keyHints(state: .sub, deviceMode: .sub, handsFree: false, canTranslate: false, up: .enter, down: .escape).up,
                     "翻译不可用时不显示翻译提示(按了也不会切换)")
    }
}

/// 链:DeviceBridge.sendSwitcher → DeviceLink.sendList → HostCommand.listTop / HostCommand.list。
nonisolated final class SwitcherListTests: XCTestCase {
    func testVisibleWindowKeepsSelectionInView() {
        XCTAssertEqual(HostCommand.listTop(total: 3, selected: 2), 0, "不足一屏时从头显示")
        XCTAssertEqual(HostCommand.listTop(total: 20, selected: 0), 0)
        XCTAssertEqual(HostCommand.listTop(total: 20, selected: 10), 7, "选中项居中")
        XCTAssertEqual(HostCommand.listTop(total: 20, selected: 19), 14, "不越过末尾")
    }

    func testListCommandIsFlatAndClamped() {
        let line = HostCommand.list(title: "SWITCH APP", sel: 1, total: 8, top: 0,
                                    items: ["Ghostty", "Google Chrome", "微信", "A", "B", "C", "D"]).line
        XCTAssertTrue(line.hasPrefix(#"{"cmd":"list","title":"SWITCH APP","sel":1,"n":8,"top":0,"i0":"Ghostty""#), line)
        XCTAssertFalse(line.contains(#""i6""#), "一屏最多 6 行")
        XCTAssertTrue(line.utf8.count < 511, "单行不超过设备上限")
        XCTAssertTrue(line.allSatisfy(\.isASCII), "设备只显示 ASCII")
    }

    @MainActor func testListStateHints() {
        XCTAssertEqual(DeviceStateMapper.keyHints(state: .list, deviceMode: .dict, handsFree: false, canTranslate: false, up: .enter, down: .escape),
                       .init(ok: .check, up: .up, down: .down))
    }
}

/// 链:PillView.surface → PillPresentation.surface(胶囊与字幕的交互规则)。
nonisolated final class PillPresentationTests: XCTestCase {
    private func surface(recording: Bool = false, captions: Bool = false, collapsed: Bool = false,
                         hovering: Bool = false, agent: Bool = false) -> PillSurface {
        PillPresentation.surface(recording: recording, processing: false, showingResult: false,
                                 captionsRunning: captions, captionsCollapsed: collapsed,
                                 hovering: hovering, hasAgentNotice: agent)
    }

    func testIdleHoverOffersStartCaptions() {
        XCTAssertEqual(surface(), .capsule(liveCaptions: false))
        XCTAssertEqual(surface(hovering: true), .toolbar(captions: .start))
    }

    func testRunningCaptionsShowBarAndDictationTakesPriority() {
        XCTAssertEqual(surface(captions: true), .captionsBar)
        XCTAssertEqual(surface(captions: true, hovering: true), .captionsBar, "字幕条自身带听写 / 收起 / 停止")
        XCTAssertEqual(surface(recording: true, captions: true), .recording, "听写优先,字幕后台继续")
    }

    func testCollapsedCaptionsCanExpandBack() {
        XCTAssertEqual(surface(captions: true, collapsed: true), .capsule(liveCaptions: true))
        XCTAssertEqual(surface(captions: true, collapsed: true, hovering: true), .toolbar(captions: .expand),
                       "收起后悬停的 ◉ 是展开,不是停止,也不是重新选应用")
    }

    func testAgentNoticeOnlyWhenNotHovering() {
        XCTAssertEqual(surface(agent: true), .agentNotice)
        XCTAssertEqual(surface(hovering: true, agent: true), .toolbar(captions: .start))
    }
}

/// 链:KeyAction.deviceIcon → DeviceStateMapper.keyHints → DeviceLink.sendKeyHints(图标 ID 必须在协议的固定列表里)。
nonisolated final class KeyActionTests: XCTestCase {
    func testEveryActionHasIconExceptNone() {
        for action in KeyAction.allCases {
            XCTAssertEqual(action.deviceIcon == nil, action == .none, "\(action)")
        }
    }

    func testIconIDsFitKeysCommand() {
        for icon in DeviceIcon.allCases {
            XCTAssertLessThanOrEqual(icon.rawValue.utf8.count, HostCommand.keyHintMaxBytes, "\(icon)")
            XCTAssertTrue(icon.rawValue.allSatisfy(\.isASCII))
        }
        let line = HostCommand.keys(ok: DeviceIcon.mic.rawValue, up: DeviceIcon.enter.rawValue, down: "").line
        XCTAssertEqual(line, #"{"cmd":"keys","ok":"mic","up":"enter","down":""}"#)
    }
}

/// 链:DeviceLink.onKey → DeviceBridge.handle → KeyPressTracker(按压归属、松开判定短按、防抖)。
nonisolated final class KeyPressTrackerTests: XCTestCase {
    func testQuickPressIsTapOnRelease() {
        var t = KeyPressTracker()
        XCTAssertEqual(t.began(.down, owner: .normal), .normal)
        XCTAssertEqual(t.ended(.down)?.isTap, true)
    }

    func testLongPressSuppressesTap() {
        var t = KeyPressTracker()
        _ = t.began(.down, owner: .normal)
        XCTAssertEqual(t.longPressed(.down), .normal)
        let end = t.ended(.down)
        XCTAssertEqual(end?.owner, .normal)
        XCTAssertEqual(end?.isTap, false, "长按后松开不能再触发短按动作(否则长按下键会先发 Esc)")
    }

    func testPressKeepsOwnerAfterModeChanges() {
        var t = KeyPressTracker()
        // 在列表里按下 OK;列表随后关闭,这次按压的松开仍归列表,不能落到听写。
        XCTAssertEqual(t.began(.ok, owner: .switcher), .switcher)
        XCTAssertEqual(t.ended(.ok)?.owner, .switcher)
    }

    func testLockoutIgnoresWholeBouncePress() {
        var t = KeyPressTracker()
        let now = Date()
        t.lockOut(.ok, for: 0.25, from: now)
        XCTAssertNil(t.began(.ok, owner: .normal, at: now.addingTimeInterval(0.1)))
        XCTAssertNil(t.longPressed(.ok))
        XCTAssertNil(t.ended(.ok), "被锁定的按压整次忽略,松开也不会触发")
        XCTAssertEqual(t.began(.ok, owner: .normal, at: now.addingTimeInterval(0.3)), .normal)
    }

    func testUpWithoutDownIsIgnored() {
        var t = KeyPressTracker()
        XCTAssertNil(t.ended(.up))
        XCTAssertNil(t.longPressed(.up))
    }
}

/// 链:FirmwareFlasher.run → FirmwareBundle.validate / EsptoolRunner.mac / EsptoolRunner.progress。
nonisolated final class FirmwareChainTests: XCTestCase {
    func testValidateRejectsImagesReachingCardID() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fw-test-\(UUID().uuidString).bin")
        try Data(count: 0x20).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let tool = URL(fileURLWithPath: "/usr/bin/true")
        let safe = FirmwareBundle(version: "t", flashArgs: [], images: [(0x10000, file)], esptool: tool)
        XCTAssertNoThrow(try safe.validate())
        let unsafe = FirmwareBundle(version: "t", flashArgs: [], images: [(FirmwareBundle.cardIDStart - 0x10, file)], esptool: tool)
        XCTAssertThrowsError(try unsafe.validate())
        let missing = FirmwareBundle(version: "t", flashArgs: [], images: [(0x0, file.appendingPathExtension("nope"))], esptool: tool)
        XCTAssertThrowsError(try missing.validate())
    }

    func testEsptoolOutputParsing() {
        XCTAssertEqual(EsptoolRunner.mac(in: "Chip type: ESP32-C3\nMAC: 12:34:56:ab:cd:ef\nHard resetting"), "123456abcdef")
        XCTAssertNil(EsptoolRunner.mac(in: "A fatal error occurred"))
        XCTAssertEqual(EsptoolRunner.progress(in: "Writing at 0x00010000 [=====>     ]  35.2% 442368/1251760 bytes")!, 0.352, accuracy: 1e-6)
        XCTAssertNil(EsptoolRunner.progress(in: "Connecting...."))
    }
}

/// 链:引导 / 设置的模型列表 → ModelCatalog(推荐顺序是用户指定的)。
nonisolated final class ModelCatalogTests: XCTestCase {
    func testRecommendedOrder() {
        // 本地模型按用户指定的推荐顺序在前,云端模型排在最后。
        XCTAssertEqual(ModelCatalog.all.filter { $0.cloudProvider == nil }.map(\.id),
                       ["whisper-turbo-632", "sensevoice-small", "apple-speech", "whisper-turbo", "whisper-small"])
        XCTAssertEqual(ModelCatalog.all.suffix(CloudProvider.allCases.count).map(\.id), CloudProvider.allCases.map(\.modelID))
        XCTAssertEqual(ModelCatalog.defaultModelID, ModelCatalog.all.first?.id)
    }
}
