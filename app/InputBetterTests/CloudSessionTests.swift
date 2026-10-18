import Foundation
import Network
import XCTest
@testable import InputBetter

/// 链:StreamingCloudSession.feed → CloudStreamPump.run → connect → CloudConnection.send
///  → (服务端)→ CloudConnection.receive → RealtimeCodec.parse → .ready / .final / .completed
///  → finish → 等就绪(超时则报告 CloudASRError.timeout)→ finishMessages → 等完成 → 拼接定稿。
/// 用本机的 WebSocket 测试服务器(Network 框架)模拟云端,验证就绪超时、断线重连和放弃重连。
nonisolated final class CloudSessionTests: XCTestCase {
    /// 测试用的短超时 / 短退避。
    private let fast = CloudStreamTiming(readyTimeout: .milliseconds(400), finishTimeout: .seconds(2),
                                         initialBackoff: .milliseconds(50), maxBackoff: .milliseconds(200))

    func testDictationHappyPath() async throws {
        let server = try await TestWebSocketServer { _, peer in
            peer.send("ready")
            peer.onMessage { text in
                if text == "finish" {
                    peer.send("final:你好")
                    peer.send("done")
                }
            }
        }
        defer { server.stop() }
        let session = StreamingCloudSession(purpose: .dictation, serviceName: "Test", timing: fast) {
            TestCodec(url: server.url)
        }
        let collector = Self.collectFailures(session)
        session.feed([Float](repeating: 0, count: 3_200))
        try await Task.sleep(for: .milliseconds(200))
        let text = await session.finish()
        XCTAssertEqual(text, "你好")
        let failures = await collector.value
        XCTAssertEqual(failures, [], "正常结束不报告错误")
    }

    /// 连上了但服务端一直不确认就绪:结束时报告超时(设置页「测试连接」靠它拿到失败)。
    func testReadyTimeoutIsReportedOnFinish() async throws {
        let server = try await TestWebSocketServer { _, _ in }  // 什么都不发
        defer { server.stop() }
        let session = StreamingCloudSession(purpose: .dictation, serviceName: "Test", timing: fast) {
            TestCodec(url: server.url)
        }
        let collector = Self.collectFailures(session)
        session.feed([Float](repeating: 0, count: 1_600))
        let text = await session.finish()
        XCTAssertEqual(text, "")
        let failures = await collector.value
        XCTAssertEqual(failures, [CloudASRError.timeout("Test").localizedDescription])
    }

    /// 字幕:就绪过的连接断开后自动重连;之后连续几次都没能就绪就放弃并报告错误(不再无限重连)。
    func testSubtitlesGiveUpAfterRepeatedFailedReconnects() async throws {
        let server = try await TestWebSocketServer { index, peer in
            guard index == 0 else { return }  // 重连之后的连接都不就绪
            peer.send("ready")
            peer.send("partial:半句")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { peer.close() }
        }
        defer { server.stop() }
        let session = StreamingCloudSession(purpose: .subtitles, serviceName: "Test", timing: fast) {
            TestCodec(url: server.url)
        }
        let events = Task { () -> [TranscriptEvent] in
            var all: [TranscriptEvent] = []
            for await event in session.events {
                all.append(event)
                if case .failure = event { break }
            }
            return all
        }
        // 字幕一直有音频送进来(重连在处理下一个音频包时进行)。
        let feeder = Task {
            while !Task.isCancelled {
                session.feed([Float](repeating: 0, count: 1_600))
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let received = await withTaskGroup(of: [TranscriptEvent]?.self) { group in
            group.addTask { await events.value }
            group.addTask { try? await Task.sleep(for: .seconds(8)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        try await Task.sleep(for: .milliseconds(400))  // 放弃之后继续送音频,也不应再重连
        feeder.cancel()
        session.cancel()
        let all = try XCTUnwrap(received, "连续失败后应当报告错误")
        XCTAssertTrue(all.contains(.final("半句")), "断线时的中间结果先定稿,不丢字")
        guard case .failure(let message)? = all.last else { return XCTFail("最后一个事件应当是错误") }
        XCTAssertEqual(message, CloudASRError.timeout("Test").localizedDescription)
        XCTAssertEqual(server.connectionCount, 1 + CloudStreamPump.maxFailedAttempts, "放弃后不再重连")
    }

    func testFatalErrorsAreNotRetried() {
        XCTAssertTrue(CloudASRError.rejected(status: 401).isFatal)
        XCTAssertTrue(CloudASRError.rejected(status: 403).isFatal)
        XCTAssertTrue(CloudASRError.rejected(status: 402).isFatal, "欠费 / 额度用完")
        XCTAssertFalse(CloudASRError.rejected(status: 503).isFatal, "服务端临时错误可以重连")
        XCTAssertFalse(CloudASRError.timeout("Test").isFatal)
        XCTAssertTrue(CloudASRError.timeout("Soniox").localizedDescription.contains("Soniox"), "超时错误里带服务名")
    }

    /// 收集会话报告的错误(事件流结束时返回)。
    private static func collectFailures(_ session: ASRSession) -> Task<[String], Never> {
        Task.detached {
            var failures: [String] = []
            for await event in session.events {
                if case .failure(let message) = event { failures.append(message) }
            }
            return failures
        }
    }
}

// MARK: - 测试用编解码器与服务器

/// 文本协议:服务端发 "ready" / "partial:x" / "final:x" / "done" / "error:x";客户端结束时发 "finish"。
private nonisolated struct TestCodec: RealtimeCodec {
    let url: URL
    let waitsForReady = true
    let chunkBytes = 3_200
    let completesOnFinalAfterFinish = false

    func makeRequest() throws -> URLRequest { URLRequest(url: url) }
    func startMessages() throws -> [URLSessionWebSocketTask.Message] { [] }
    func audioMessage(_ pcm16: Data) throws -> URLSessionWebSocketTask.Message { .data(pcm16) }
    func finishMessages(lastChunk: Data) throws -> [URLSessionWebSocketTask.Message] { [.string("finish")] }

    mutating func parse(_ message: URLSessionWebSocketTask.Message) -> [CodecEvent] {
        guard case .string(let text) = message else { return [] }
        if text == "ready" { return [.ready] }
        if text == "done" { return [.completed] }
        if text.hasPrefix("partial:") { return [.partial(String(text.dropFirst(8)))] }
        if text.hasPrefix("final:") { return [.final(String(text.dropFirst(6)))] }
        if text.hasPrefix("error:") { return [.failure(String(text.dropFirst(6)))] }
        return []
    }
}

/// 本机 WebSocket 服务器(Network 框架)。每条连接按序号交给 `behavior` 处理。
private nonisolated final class TestWebSocketServer: @unchecked Sendable {
    /// 一条服务端连接。
    final class Peer: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }

        func send(_ text: String) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
        }

        func onMessage(_ handler: @escaping @Sendable (String) -> Void) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard error == nil else { return }
                if let data, let text = String(data: data, encoding: .utf8) { handler(text) }
                self?.onMessage(handler)
            }
        }

        func close() { connection.cancel() }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ib.test.ws")
    private let lock = NSLock()
    private var peers: [Peer] = []
    private(set) var port: UInt16 = 0

    var connectionCount: Int { lock.withLock { peers.count } }
    var url: URL { URL(string: "ws://127.0.0.1:\(port)/")! }

    init(behavior: @escaping @Sendable (_ index: Int, _ peer: Peer) -> Void) async throws {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let peer = Peer(connection)
            let index = lock.withLock { () -> Int in
                peers.append(peer)
                return peers.count - 1
            }
            connection.stateUpdateHandler = { state in
                if case .ready = state { behavior(index, peer) }
            }
            connection.start(queue: queue)
        }
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if resumed.set() { continuation.resume(returning: listener?.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { peers }.forEach { $0.close() }
    }
}

/// 只允许置位一次的标记(continuation 只能 resume 一次)。
private nonisolated final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// 第一次调用返回 true。
    func set() -> Bool {
        lock.withLock {
            defer { value = true }
            return !value
        }
    }
}
