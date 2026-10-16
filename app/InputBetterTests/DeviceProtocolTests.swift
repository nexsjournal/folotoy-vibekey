import XCTest
@testable import InputBetter

/// Passport 协议层的单元测试:消息解析、命令编码、帧解复用、ADPCM 解码、按键去重。
/// 只测纯函数 / 值类型,不碰串口和蓝牙。
// 被测类型都是 nonisolated;测试类也标 nonisolated,避免默认 MainActor 隔离与 XCTestCase 的初始化器冲突。
nonisolated final class DeviceProtocolTests: XCTestCase {

    // MARK: - 设备 → Mac 消息解析

    func testParseHello() {
        let line = #"{"t":"hello","fw":"inputbetter","proto":1,"ver":"0.1.0","boot":"9f3a21c4"}"#
        XCTAssertEqual(
            DeviceMessage.parse(line),
            .hello(DeviceHello(firmware: "inputbetter", protocolVersion: 1, version: "0.1.0", boot: "9f3a21c4"))
        )
    }

    func testParseKeyWithLogPrefix() {
        // USB 上日志前缀可能和 JSON 落在同一行,解析从 {"t": 开始。
        let line = #"I (1234) ib_main: {"t":"key","k":"ok","e":"down","seq":12,"boot":"9f3a21c4"}"#
        XCTAssertEqual(
            DeviceMessage.parse(line),
            .key(DeviceKeyReport(key: .ok, event: .down, seq: 12, boot: "9f3a21c4"))
        )
        XCTAssertEqual(
            DeviceMessage.parse(#"{"t":"key","k":"down","e":"long","seq":3,"boot":"b"}"#),
            .key(DeviceKeyReport(key: .down, event: .long, seq: 3, boot: "b"))
        )
    }

    func testParseKeyAck() {
        // 关闭 agent 通知的那次按压带 "ack":1。
        XCTAssertEqual(
            DeviceMessage.parse(#"{"t":"key","k":"up","e":"down","seq":4,"boot":"b","ack":1}"#),
            .key(DeviceKeyReport(key: .up, event: .down, seq: 4, boot: "b", ack: true))
        )
        XCTAssertEqual(
            DeviceMessage.parse(#"{"t":"key","k":"up","e":"up","seq":5,"boot":"b","ack":0}"#),
            .key(DeviceKeyReport(key: .up, event: .up, seq: 5, boot: "b", ack: false))
        )
        guard case .key(let plain)? = DeviceMessage.parse(#"{"t":"key","k":"ok","e":"up","seq":6,"boot":"b"}"#) else {
            return XCTFail("expected key")
        }
        XCTAssertFalse(plain.ack)
    }

    func testParseBattery() {
        XCTAssertEqual(
            DeviceMessage.parse(#"{"t":"bat","soc":87,"mv":4012,"chg":0}"#),
            .battery(DeviceBatteryReport(percent: 87, millivolts: 4012, charging: false))
        )
        // 读不到时为 -1。
        XCTAssertEqual(
            DeviceMessage.parse(#"{"t":"bat","soc":-1,"mv":-1,"chg":1}"#),
            .battery(DeviceBatteryReport(percent: nil, millivolts: nil, charging: true))
        )
    }

    func testParsePong() {
        XCTAssertEqual(DeviceMessage.parse(#"{"t":"pong"}"#), .pong)
        XCTAssertEqual(DeviceMessage.parse("{\"t\":\"pong\"}\r"), .pong)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(DeviceMessage.parse("I (321) wifi: started"))
        XCTAssertNil(DeviceMessage.parse(""))
        XCTAssertNil(DeviceMessage.parse(#"{"t":"pong""#))  // 被截断
        XCTAssertNil(DeviceMessage.parse(#"{"t":"weird"}"#))  // 未知类型
        XCTAssertNil(DeviceMessage.parse(#"{"t":"key","k":"left","e":"down","seq":1}"#))  // 未知按键
        XCTAssertNil(DeviceMessage.parse(#"{"t":"key","k":"ok"}"#))  // 缺事件
        XCTAssertNil(DeviceMessage.parse(#"{"t":"hello","proto":1}"#))  // 缺 fw
        XCTAssertNil(DeviceMessage.parse(#"{"cmd":"hello"}"#))  // Mac → 设备的命令
    }

    func testSplitLinesAcrossChunks() {
        var decoder = StreamDecoder()
        XCTAssertEqual(decoder.feed(Data(#"{"t":"po"#.utf8)), [])
        let items = decoder.feed(Data("ng\"}\r\n{\"t\":\"bat\",\"soc\":5".utf8))
        XCTAssertEqual(items, [.line(#"{"t":"pong"}"#)])
        let rest = decoder.feed(Data(",\"mv\":3600,\"chg\":0}\nI (9) log line\n".utf8))
        XCTAssertEqual(rest.count, 2)
        guard case .line(let bat) = rest.first else { return XCTFail("expected line") }
        XCTAssertEqual(
            DeviceMessage.parse(bat),
            .battery(DeviceBatteryReport(percent: 5, millivolts: 3600, charging: false))
        )
        guard case .line(let log) = rest.last else { return XCTFail("expected line") }
        XCTAssertNil(DeviceMessage.parse(log))
    }

    func testOverlongLineIsDropped() {
        var decoder = StreamDecoder(maxLineBytes: 16)
        let items = decoder.feed(Data((String(repeating: "x", count: 40) + "\n" + #"{"t":"pong"}"# + "\n").utf8))
        XCTAssertEqual(items, [.line(#"{"t":"pong"}"#)])
    }

    // MARK: - Mac → 设备命令编码

    func testSimpleCommands() {
        XCTAssertEqual(HostCommand.hello.line, #"{"cmd":"hello"}"#)
        XCTAssertEqual(HostCommand.ping.line, #"{"cmd":"ping"}"#)
        XCTAssertEqual(HostCommand.bye.line, #"{"cmd":"bye"}"#)
        XCTAssertEqual(HostCommand.mic(true).line, #"{"cmd":"mic","on":1}"#)
        XCTAssertEqual(HostCommand.mic(false).line, #"{"cmd":"mic","on":0}"#)
        XCTAssertEqual(HostCommand.hello.data, Data("{\"cmd\":\"hello\"}\n".utf8))
    }

    func testLevelIsClamped() {
        XCTAssertEqual(HostCommand.level(42).line, #"{"cmd":"level","v":42}"#)
        XCTAssertEqual(HostCommand.level(150).line, #"{"cmd":"level","v":100}"#)
        XCTAssertEqual(HostCommand.level(-5).line, #"{"cmd":"level","v":0}"#)
    }

    func testConfigEncoding() {
        let config = DeviceConfig(passportMic: true, engine: "Whisper Turbo", screenOff: 60, sound: true)
        XCTAssertEqual(
            HostCommand.config(config, clock: 1_789_097_696).line,
            #"{"cmd":"config","mic":1,"engine":"Whisper Turbo","screen_off":60,"clock":1789097696,"sound":1}"#
        )
        let off = DeviceConfig(passportMic: false, engine: "", screenOff: -3, sound: false)
        XCTAssertEqual(
            HostCommand.config(off, clock: 5).line,
            #"{"cmd":"config","mic":0,"engine":"","screen_off":0,"clock":5,"sound":0}"#
        )
    }

    func testStateEncodingEscapesAndClamps() {
        XCTAssertEqual(
            HostCommand.state(.rec, mode: .dict, msg: "").line,
            #"{"cmd":"state","st":"rec","mode":"dict","msg":""}"#
        )
        XCTAssertEqual(
            HostCommand.state(.err, mode: .tr, msg: #"say "hi" \"#).line,
            #"{"cmd":"state","st":"err","mode":"tr","msg":"say \"hi\" \\"}"#
        )
        // 结果必须是能解析的扁平 JSON。
        let json = HostCommand.state(.sub, mode: .sub, msg: "a\tb\u{1}c").line
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(object?["msg"] as? String, "a b c")
    }

    func testKeyHintsEncoding() {
        XCTAssertEqual(
            HostCommand.keys(ok: "HOLD TALK", up: "ENTER", down: "ESC").line,
            #"{"cmd":"keys","ok":"HOLD TALK","up":"ENTER","down":"ESC"}"#
        )
        // 各字段截到 11 字节;空字符串表示无动作,照常发送。
        XCTAssertEqual(
            HostCommand.keys(ok: "Push to talk now", up: "", down: "取消").line,
            #"{"cmd":"keys","ok":"Push to tal","up":"","down":"qu xiao"}"#
        )
    }

    func testAgentEncoding() {
        XCTAssertEqual(
            HostCommand.agent(.done, msg: "Claude Code").line,
            #"{"cmd":"agent","ev":"done","msg":"Claude Code"}"#
        )
        XCTAssertEqual(
            HostCommand.agent(.input, msg: "Codex").line,
            #"{"cmd":"agent","ev":"input","msg":"Codex"}"#
        )
        XCTAssertEqual(HostCommand.agent(.clear, msg: "").line, #"{"cmd":"agent","ev":"clear","msg":""}"#)
        XCTAssertEqual(
            HostCommand.agent(.done, msg: "A very long agent source name").line,
            #"{"cmd":"agent","ev":"done","msg":"A very long agent sourc"}"#
        )
    }

    func testASCIIClamp() {
        XCTAssertEqual(DeviceText.ascii("Copied"), "Copied")
        XCTAssertEqual(DeviceText.ascii("Café"), "Cafe")
        XCTAssertEqual(DeviceText.ascii("微信"), "wei xin")
        let long = DeviceText.ascii("Visual Studio Code - Insiders Edition")
        XCTAssertEqual(long, "Visual Studio Code - In")
        XCTAssertEqual(long.utf8.count, 23)
        for sample in ["😀 Music", "日本語のアプリケーション名がとても長い", "Ünïcödé\nline"] {
            let out = DeviceText.ascii(sample)
            XCTAssertLessThanOrEqual(out.utf8.count, 23, sample)
            XCTAssertTrue(out.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }, sample)
        }
        // 截断发生在转义之前:23 个引号编码后仍是 23 个设备字节。
        let quotes = String(repeating: "\"", count: 30)
        XCTAssertEqual(DeviceText.ascii(quotes).utf8.count, 23)
    }

    func testLocalClockAddsTimeZoneOffset() {
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(HostCommand.localClock(now: date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!), 1_000 + 28_800)
        XCTAssertEqual(HostCommand.localClock(now: date, timeZone: TimeZone(secondsFromGMT: 0)!), 1_000)
    }

    // MARK: - 帧解复用

    private func frame(type: UInt8 = 0x02, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        [UInt8](DeviceFrame.encode(type: type, seq: seq, payload: Data(payload))!)
    }

    func testFrameInterleavedMidLine() {
        let payload = (0..<300).map { UInt8($0 & 0xFF) }  // 负载里含 0xFF / 0xFE 也不影响
        var bytes = [UInt8](#"{"t":"key","k":"up","#.utf8)
        bytes += frame(seq: 7, payload: payload)
        bytes += [UInt8](#""e":"up","seq":1,"boot":"a"}"#.utf8) + [0x0A]

        var decoder = StreamDecoder()
        let items = decoder.feed(Data(bytes))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first, .frame(type: 0x02, seq: 7, payload: Data(payload)))
        guard case .line(let line) = items.last else { return XCTFail("expected line") }
        XCTAssertEqual(DeviceMessage.parse(line), .key(DeviceKeyReport(key: .up, event: .up, seq: 1, boot: "a")))
    }

    func testFrameSplitByteByByte() {
        let payload = [UInt8](repeating: 0xAB, count: 328)
        let bytes = frame(seq: 255, payload: payload) + [UInt8](#"{"t":"pong"}"#.utf8) + [0x0A]
        var decoder = StreamDecoder()
        var items: [StreamDecoder.Item] = []
        for b in bytes {
            items += decoder.feed(Data([b]))
        }
        XCTAssertEqual(items, [.frame(type: 0x02, seq: 255, payload: Data(payload)), .line(#"{"t":"pong"}"#)])
    }

    func testResyncOnBadSecondByte() {
        // 0xFF 后面不是 0xFE:只丢 0xFF,后面的字节按文本处理。
        var decoder = StreamDecoder()
        let bytes: [UInt8] = [0xFF] + [UInt8](#"{"t":"pong"}"#.utf8) + [0x0A]
        XCTAssertEqual(decoder.feed(Data(bytes)), [.line(#"{"t":"pong"}"#)])
    }

    func testResyncOnBadLength() {
        var decoder = StreamDecoder()
        var bytes: [UInt8] = [UInt8](#"{"t":"p"#.utf8)
        bytes += [0xFF, 0xFE, 0x02, 0x01, 0x00, 0x00]  // 长度 0:非法
        bytes += [0xFF, 0xFE, 0x02, 0x02, 0xFF, 0x7F]  // 长度 32767:非法,其中的 0xFF 也不能被当成帧头
        bytes += frame(seq: 3, payload: [1, 2, 3])
        bytes += [UInt8](#"ong"}"#.utf8) + [0x0A]
        let items = decoder.feed(Data(bytes))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first, .frame(type: 0x02, seq: 3, payload: Data([1, 2, 3])))
        // 非法头的残余字节混进了这一行(这一行本身作废),但行边界没有错位……
        guard case .line(let line) = items.last else { return XCTFail("expected line") }
        XCTAssertTrue(line.hasPrefix(#"{"t":"p"#))
        XCTAssertTrue(line.hasSuffix(#"ong"}"#))
        // ……而合法帧之后的流不受影响。
        XCTAssertEqual(decoder.feed(Data(#"{"t":"pong"}"#.utf8 + [0x0A])), [.line(#"{"t":"pong"}"#)])
    }

    // MARK: - IMA ADPCM

    private func block(predictor: Int16, index: UInt8, nibbles: (Int) -> UInt8) -> [UInt8] {
        let p = UInt16(bitPattern: predictor)
        var out: [UInt8] = [UInt8(p & 0xFF), UInt8(p >> 8), index, 0]
        for i in 0..<160 {
            out.append((nibbles(2 * i) & 0x0F) | ((nibbles(2 * i + 1) & 0x0F) << 4))
        }
        return out
    }

    func testDecodeHandComputedVector() {
        // 预测值 0、索引 0,所有 nibble = 7:
        // step 7  → diff 0+7+3+1   = 11  → 11,  索引 8
        // step 16 → diff 2+16+8+4  = 30  → 41,  索引 16
        // step 34 → diff 4+34+17+8 = 63  → 104, 索引 24
        // step 73 → diff 9+73+36+18 = 136 → 240
        let samples = IMAADPCMDecoder.decodeBlock(block(predictor: 0, index: 0) { _ in 7 })
        XCTAssertEqual(samples.count, 320)
        XCTAssertEqual(Array(samples.prefix(4)), [11, 41, 104, 240].map { Float($0) / 32768 })
        XCTAssertTrue(samples.allSatisfy { $0 <= 32767.0 / 32768 })  // 饱和而不溢出
    }

    func testDecodeLowNibbleFirst() {
        // 第一个字节 0x07:低半字节 7 先解(+11,索引 8),高半字节 0 后解(step 16 → +2)。
        let samples = IMAADPCMDecoder.decodeBlock(block(predictor: 0, index: 0) { $0 == 0 ? 7 : 0 })
        XCTAssertEqual(samples[0], 11 / 32768)
        XCTAssertEqual(samples[1], 13 / 32768)
    }

    func testDecodeHeaderPredictorAndIndexClamp() {
        // 负预测值、超范围索引(按 88 处理),nibble 8 = 负方向最小步长。
        let samples = IMAADPCMDecoder.decodeBlock(block(predictor: -1000, index: 200) { _ in 8 })
        // step 32767 → diff 4095 → -5095
        XCTAssertEqual(samples[0], -5095 / 32768)
        XCTAssertEqual(samples.last, -1)  // 一直往下压,饱和在 -32768
    }

    func testDecodeSineRoundTrip() {
        let pcm: [Int16] = (0..<640).map { i in
            Int16((sin(Double(i) * 2 * .pi * 440 / 16_000) * 8_000).rounded())
        }
        var payload = Data()
        for b in 0..<2 {
            let chunk = Array(pcm[(b * 320)..<((b + 1) * 320)])
            payload.append(contentsOf: TestADPCMEncoder.encodeBlock(chunk, index: 40))
        }
        payload.append(contentsOf: [1, 2, 3])  // 末尾不足一块:忽略

        let decoded = IMAADPCMDecoder.decode(payload)
        XCTAssertEqual(decoded.count, 640)
        var errorEnergy: Double = 0
        var signalEnergy: Double = 0
        for (d, s) in zip(decoded, pcm) {
            let reference = Double(s) / 32768
            errorEnergy += pow(Double(d) - reference, 2)
            signalEnergy += reference * reference
        }
        let snr = 10 * log10(signalEnergy / errorEnergy)
        XCTAssertGreaterThan(snr, 20, "SNR \(snr) dB")
    }

    func testDecodeShortPayloadIsEmpty() {
        XCTAssertEqual(IMAADPCMDecoder.decode(Data(repeating: 0, count: 163)), [])
        XCTAssertEqual(IMAADPCMDecoder.decodeBlock([1, 2, 3]), [])
    }

    // MARK: - 去重

    func testRecentEventFilter() {
        var filter = RecentEventFilter(capacity: 2)
        XCTAssertTrue(filter.accept(boot: "a", seq: 1))
        XCTAssertFalse(filter.accept(boot: "a", seq: 1))
        XCTAssertTrue(filter.accept(boot: "b", seq: 1))  // 设备重启后 seq 重新计数
        XCTAssertTrue(filter.accept(boot: "a", seq: 2))  // 挤掉 (a,1)
        XCTAssertTrue(filter.accept(boot: "a", seq: 1))
        XCTAssertFalse(filter.accept(boot: "a", seq: 2))

        let noSeq = DeviceKeyReport(key: .ok, event: .down, seq: nil, boot: "a")
        XCTAssertTrue(filter.accept(noSeq))
        XCTAssertTrue(filter.accept(noSeq))
        let report = DeviceKeyReport(key: .ok, event: .up, seq: 9, boot: "c")
        XCTAssertTrue(filter.accept(report))
        XCTAssertFalse(filter.accept(report))
    }
}

/// 测试专用的 IMA ADPCM 编码器(与 IMAADPCMDecoder 的表一致),用于构造往返测试数据。
private nonisolated enum TestADPCMEncoder {
    static func encodeBlock(_ pcm: [Int16], index startIndex: Int) -> [UInt8] {
        precondition(pcm.count == 320)
        var predictor = Int32(pcm[0])
        var index = startIndex
        let p = UInt16(bitPattern: Int16(predictor))
        var out: [UInt8] = [UInt8(p & 0xFF), UInt8(p >> 8), UInt8(index), 0]
        var low: UInt8 = 0
        for (i, sample) in pcm.enumerated() {
            let code = encodeSample(sample, predictor: &predictor, index: &index)
            if i % 2 == 0 {
                low = code
            } else {
                out.append(low | (code << 4))
            }
        }
        return out
    }

    private static func encodeSample(_ sample: Int16, predictor: inout Int32, index: inout Int) -> UInt8 {
        var step = IMAADPCMDecoder.stepTable[index]
        var diff = Int32(sample) - predictor
        var code: UInt8 = 0
        if diff < 0 {
            code = 8
            diff = -diff
        }
        var delta = step >> 3
        if diff >= step { code |= 4; diff -= step; delta += step }
        step >>= 1
        if diff >= step { code |= 2; diff -= step; delta += step }
        step >>= 1
        if diff >= step { code |= 1; delta += step }
        predictor += (code & 8 != 0) ? -delta : delta
        predictor = min(max(predictor, -32768), 32767)
        index = min(max(index + IMAADPCMDecoder.indexTable[Int(code)], 0), 88)
        return code
    }
}
