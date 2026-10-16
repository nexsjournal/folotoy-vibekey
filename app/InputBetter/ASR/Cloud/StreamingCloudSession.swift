import Foundation

/// 云端流式识别会话(所有流式服务共用),协议细节交给 RealtimeCodec。
/// 职责:建立 WebSocket、等待服务端就绪、按包大小发送 PCM、结束时补发尾包并等待定稿、
/// 字幕模式下连接中断自动重连(把当时的中间结果当作定稿,不丢字)、把错误报告给上层。
/// 线程:`feed` / `finish` 可在任意线程调用;内部用一个处理任务串行发送,接收在另一个任务里。
nonisolated final class StreamingCloudSession: ASRSession, @unchecked Sendable {
    let events: AsyncStream<TranscriptEvent>
    private let sink: AsyncStream<TranscriptEvent>.Continuation
    private let inbox: AsyncStream<Command>.Continuation
    private var worker: Task<String, Never>!
    private let makeCodec: @Sendable () -> any RealtimeCodec
    private let purpose: ASRPurpose
    private let state = SharedState()

    /// 结束后等待定稿的最长时间。
    private let finishTimeout: Duration = .seconds(6)
    /// 等待服务端就绪的最长时间。
    private let readyTimeout: Duration = .seconds(8)

    private enum Command: Sendable {
        case audio([Float])
        case finish
    }

    /// - Parameter makeCodec: 每次(重新)连接都生成新的编解码器(新的任务 ID、清空去重状态)。
    init(purpose: ASRPurpose, makeCodec: @escaping @Sendable () -> any RealtimeCodec) {
        self.purpose = purpose
        self.makeCodec = makeCodec
        (events, sink) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let (commands, inbox) = AsyncStream.makeStream(of: Command.self)
        self.inbox = inbox
        worker = Task.detached(priority: .userInitiated) { [unowned self] in
            await self.run(commands)
        }
    }

    func feed(_ samples: [Float]) { inbox.yield(.audio(samples)) }

    func finish() async -> String {
        inbox.yield(.finish)
        inbox.finish()
        let text = await worker.value
        sink.finish()
        return text
    }

    func cancel() {
        inbox.finish()
        worker.cancel()
        state.connection?.close()
        sink.finish()
    }

    // MARK: - 发送端(串行)

    private func run(_ commands: AsyncStream<Command>) async -> String {
        var pending = Data()
        var backoff: Duration = .seconds(1)
        connect()

        for await command in commands {
            if Task.isCancelled { break }
            // 字幕模式:连接意外断开时重连(指数退避),积压的音频最多保留 5 秒。
            if state.lost, purpose == .subtitles {
                commitPartialAsFinal()
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(30))
                pending = pending.suffix(16_000 * 2 * 5)
                connect()
            }
            switch command {
            case .audio(let samples):
                pending.append(AudioFormats.pcm16(samples))
                if state.canSendAudio(waitsForReady: state.codec.waitsForReady) {
                    if !pending.isEmpty { backoff = .seconds(1) }
                    sendChunks(&pending, keepRemainder: true)
                }
            case .finish:
                await waitUntil(readyTimeout) { self.state.ready || self.state.failed || self.state.lost }
                if state.ready, !state.lost {
                    sendChunks(&pending, keepRemainder: true)
                    state.markFinishing()
                    send((try? state.codec.finishMessages(lastChunk: pending)) ?? [])
                    pending.removeAll()
                    let completesOnFinal = state.codec.completesOnFinalAfterFinish
                    await waitUntil(finishTimeout) {
                        self.state.completed || self.state.failed || self.state.lost
                            || (completesOnFinal && self.state.finalAfterFinish)
                    }
                }
                state.connection?.close()
                return state.transcript()
            }
        }
        state.connection?.close()
        return state.transcript()
    }

    private func connect() {
        let codec = makeCodec()
        state.reset(codec: codec)
        do {
            let connection = try CloudConnection(request: codec.makeRequest()) { [weak self] message in
                self?.receive(message)
            } onClose: { [weak self] error in
                self?.connectionClosed(error)
            }
            state.connection = connection
            send((try? codec.startMessages()) ?? [])
        } catch {
            report(error.localizedDescription)
        }
    }

    private func sendChunks(_ pending: inout Data, keepRemainder: Bool) {
        let size = state.codec.chunkBytes
        while pending.count >= size {
            let chunk = pending.prefix(size)
            pending.removeFirst(size)
            if let message = try? state.codec.audioMessage(Data(chunk)) { send([message]) }
        }
        if !keepRemainder, !pending.isEmpty, let message = try? state.codec.audioMessage(pending) {
            send([message])
            pending.removeAll()
        }
    }

    private func send(_ messages: [URLSessionWebSocketTask.Message]) {
        for message in messages { state.connection?.send(message) }
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - 接收端

    private func receive(_ message: URLSessionWebSocketTask.Message) {
        for event in state.parse(message) {
            switch event {
            case .ready:
                state.markReady()
            case .partial(let text):
                state.setPartial(text)
                sink.yield(.partial(text))
            case .final(let text):
                state.appendFinal(text)
                sink.yield(.final(text))
            case .completed:
                state.markCompleted()
            case .failure(let message):
                // 字幕运行中途的服务端错误(如会话时长上限)走重连;还没就绪就失败通常是配置问题,直接报告。
                if purpose == .subtitles, state.everReady {
                    Log.asr.notice("cloud stream error, reconnecting: \(message, privacy: .public)")
                    state.markLost()
                } else {
                    report(message)
                }
            }
        }
    }

    private func connectionClosed(_ error: Error?) {
        guard !state.finishing, !state.completed else { return }
        if purpose == .subtitles, state.everReady {
            state.markLost()
        } else if let error {
            report(error.localizedDescription)
        }
    }

    private func report(_ message: String) {
        state.markFailed()
        sink.yield(.failure(message))
    }

    /// 重连前把当时的中间结果作为定稿,避免丢字。
    private func commitPartialAsFinal() {
        if let text = state.takePartial(), !text.isEmpty {
            state.appendFinal(text)
            sink.yield(.final(text))
            sink.yield(.partial(""))
        }
    }
}

/// 会话的共享状态(发送端、接收端、回调在不同线程,统一加锁)。
private nonisolated final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _codec: any RealtimeCodec = PlaceholderCodec()
    private var _connection: CloudConnection?
    private var finals: [String] = []
    private var partial = ""
    private var flags = (ready: false, everReady: false, completed: false, failed: false, lost: false,
                         finishing: false, finalAfterFinish: false)

    var codec: any RealtimeCodec { lock.withLock { _codec } }
    var connection: CloudConnection? {
        get { lock.withLock { _connection } }
        set { lock.withLock { _connection = newValue } }
    }
    var ready: Bool { lock.withLock { flags.ready } }
    var everReady: Bool { lock.withLock { flags.everReady } }
    var completed: Bool { lock.withLock { flags.completed } }
    var failed: Bool { lock.withLock { flags.failed } }
    var lost: Bool { lock.withLock { flags.lost } }
    var finishing: Bool { lock.withLock { flags.finishing } }
    var finalAfterFinish: Bool { lock.withLock { flags.finalAfterFinish } }

    func reset(codec: any RealtimeCodec) {
        lock.withLock {
            _codec = codec
            _connection = nil
            flags.ready = false
            flags.lost = false
            flags.completed = false
        }
    }

    func canSendAudio(waitsForReady: Bool) -> Bool {
        lock.withLock { !flags.lost && !flags.failed && (flags.ready || !waitsForReady) && _connection != nil }
    }

    /// 解析在接收线程上进行,用锁保护编解码器的去重状态。
    func parse(_ message: URLSessionWebSocketTask.Message) -> [CodecEvent] {
        lock.withLock { _codec.parse(message) }
    }

    func markReady() { lock.withLock { flags.ready = true; flags.everReady = true } }
    func markCompleted() { lock.withLock { flags.completed = true } }
    func markFailed() { lock.withLock { flags.failed = true } }
    func markLost() { lock.withLock { flags.lost = true } }
    func markFinishing() { lock.withLock { flags.finishing = true } }
    func setPartial(_ text: String) { lock.withLock { partial = text } }

    func appendFinal(_ text: String) {
        lock.withLock {
            finals.append(text)
            if flags.finishing { flags.finalAfterFinish = true }
        }
    }

    func takePartial() -> String? {
        lock.withLock {
            defer { partial = "" }
            return partial
        }
    }

    /// 完整文本:定稿 + 没来得及定稿的中间结果(超时或断开时也不丢字)。
    func transcript() -> String {
        lock.withLock { TranscriptText.join(finals + [partial]) }
    }
}

/// 尚未连接时的占位编解码器。
private nonisolated struct PlaceholderCodec: RealtimeCodec {
    let waitsForReady = true
    let chunkBytes = 3_200
    let completesOnFinalAfterFinish = false
    func makeRequest() throws -> URLRequest { throw CloudASRError.badURL }
    func startMessages() throws -> [URLSessionWebSocketTask.Message] { [] }
    func audioMessage(_ pcm16: Data) throws -> URLSessionWebSocketTask.Message { .data(pcm16) }
    func finishMessages(lastChunk: Data) throws -> [URLSessionWebSocketTask.Message] { [] }
    mutating func parse(_ message: URLSessionWebSocketTask.Message) -> [CodecEvent] { [] }
}

/// 一条 WebSocket 连接:持续接收,按顺序发送,关闭时回调一次。
nonisolated final class CloudConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private let onMessage: @Sendable (URLSessionWebSocketTask.Message) -> Void
    private let onClose: @Sendable (Error?) -> Void
    private let lock = NSLock()
    private var closed = false

    init(request: URLRequest,
         onMessage: @escaping @Sendable (URLSessionWebSocketTask.Message) -> Void,
         onClose: @escaping @Sendable (Error?) -> Void) throws {
        self.onMessage = onMessage
        self.onClose = onClose
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1_048_576
        task.resume()
        receiveNext()
    }

    func send(_ message: URLSessionWebSocketTask.Message) {
        task.send(message) { [weak self] error in
            if let error { self?.finish(error) }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
        finish(nil)
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.onMessage(message)
                self.receiveNext()
            case .failure(let error):
                self.finish(error)
            }
        }
    }

    private func finish(_ error: Error?) {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if first { onClose(error) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(closeCode == .normalClosure ? nil : CloudASRError.server(reason.map { String(decoding: $0, as: UTF8.self) } ?? "closed \(closeCode.rawValue)"))
    }

    /// 握手失败(如 401 / 403)在这里拿到 HTTP 状态码,给出可读的错误。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 101 {
            let message = http.statusCode == 401 || http.statusCode == 403
                ? String(localized: "API Key 无效或没有权限（HTTP \(http.statusCode)）", bundle: .l10n)
                : String(localized: "云端识别连接失败（HTTP \(http.statusCode)）", bundle: .l10n)
            finish(CloudASRError.server(message))
        } else if let error {
            finish(error)
        }
    }
}
