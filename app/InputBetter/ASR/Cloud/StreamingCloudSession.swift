import Foundation

/// 云端流式识别会话(所有流式服务共用),协议细节交给 RealtimeCodec。
/// 职责:建立 WebSocket、等待服务端就绪、按包大小发送 PCM、结束时补发尾包并等待定稿、
/// 字幕模式下连接中断自动重连(把当时的中间结果当作定稿,不丢字)、把错误报告给上层。
/// 线程:`feed` / `finish` / `cancel` 可在任意线程调用;发送在 `CloudStreamPump.run` 这个后台任务里串行进行,
/// 接收在 URLSession 的回调线程上,双方通过加锁的 SharedState 共享状态。
/// 生命周期:后台任务只持有 pump(不持有会话本身),会话先释放也不会访问已释放的对象。
nonisolated final class StreamingCloudSession: ASRSession, @unchecked Sendable {
    let events: AsyncStream<TranscriptEvent>
    private let sink: AsyncStream<TranscriptEvent>.Continuation
    private let inbox: AsyncStream<CloudStreamPump.Command>.Continuation
    private let pump: CloudStreamPump
    private let worker: Task<String, Never>

    /// - Parameters:
    ///   - serviceName: 服务名(超时等错误里显示);
    ///   - timing: 超时与重连退避(测试里缩短);
    ///   - makeCodec: 每次(重新)连接都生成新的编解码器(新的任务 ID、清空去重状态)。
    init(purpose: ASRPurpose, serviceName: String, timing: CloudStreamTiming = .standard,
         makeCodec: @escaping @Sendable () -> any RealtimeCodec) {
        let (events, sink) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let (commands, inbox) = AsyncStream.makeStream(of: CloudStreamPump.Command.self)
        let pump = CloudStreamPump(purpose: purpose, serviceName: serviceName, timing: timing, makeCodec: makeCodec, sink: sink)
        self.events = events
        self.sink = sink
        self.inbox = inbox
        self.pump = pump
        worker = Task.detached(priority: .userInitiated) { [pump] in
            await pump.run(commands)
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
        pump.shutdown()
        sink.finish()
    }
}

/// 流式会话的超时与重连参数。
nonisolated struct CloudStreamTiming: Sendable {
    /// 连接后等待服务端就绪的最长时间。
    var readyTimeout: Duration = .seconds(8)
    /// 结束后等待定稿的最长时间。
    var finishTimeout: Duration = .seconds(6)
    /// 字幕重连的首次退避,之后每次翻倍,最长 `maxBackoff`。
    var initialBackoff: Duration = .seconds(1)
    var maxBackoff: Duration = .seconds(30)

    static let standard = CloudStreamTiming()
}

/// 流式会话的发送 / 接收逻辑。由会话的后台任务驱动 `run`,连接回调通过 `[weak self]` 进来。
/// 每次(重新)连接对应一个"代"(generation):旧连接的消息和关闭回调一律忽略,
/// 避免重连后旧连接迟到的关闭把新连接标成断开。
nonisolated final class CloudStreamPump: @unchecked Sendable {
    enum Command: Sendable {
        case audio([Float])
        case finish
    }

    private let purpose: ASRPurpose
    private let serviceName: String
    private let makeCodec: @Sendable () -> any RealtimeCodec
    private let sink: AsyncStream<TranscriptEvent>.Continuation
    private let timing: CloudStreamTiming
    private let state = SharedState()

    /// 字幕模式:自上次就绪以来,连续这么多次连接都没能就绪就不再重连,直接报告错误。
    static let maxFailedAttempts = 3

    init(purpose: ASRPurpose, serviceName: String, timing: CloudStreamTiming,
         makeCodec: @escaping @Sendable () -> any RealtimeCodec, sink: AsyncStream<TranscriptEvent>.Continuation) {
        self.purpose = purpose
        self.serviceName = serviceName
        self.timing = timing
        self.makeCodec = makeCodec
        self.sink = sink
    }

    /// 关闭当前连接,之后的关闭回调不再当作断线处理(会话结束 / 取消)。
    func shutdown() {
        state.markClosed()
        state.connection?.close()
    }

    // MARK: - 发送端(串行)

    func run(_ commands: AsyncStream<Command>) async -> String {
        var pending = Data()
        var backoff = timing.initialBackoff
        /// 自上次就绪以来连续失败(没能就绪)的连接次数。
        var failedAttempts = 0
        connect()

        for await command in commands {
            if Task.isCancelled { break }
            // 字幕模式:连接意外断开时重连(指数退避),积压的音频最多保留 5 秒。
            // 退避只在新一轮就绪后才复位;连续几次都没能就绪就放弃,报告最后一次的错误。
            if state.lost, !state.failed, purpose == .subtitles {
                commitPartialAsFinal()
                if state.ready {
                    failedAttempts = 0
                    backoff = timing.initialBackoff
                } else {
                    failedAttempts += 1
                }
                if failedAttempts >= Self.maxFailedAttempts {
                    Log.asr.error("cloud stream gave up after \(failedAttempts, privacy: .public) failed attempts")
                    report(state.lastError ?? CloudASRError.timeout(serviceName).localizedDescription)
                } else {
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, timing.maxBackoff)
                    pending = pending.suffix(16_000 * 2 * 5)
                    connect()
                }
            }
            switch command {
            case .audio(let samples):
                pending.append(AudioFormats.pcm16(samples))
                if state.canSendAudio(waitsForReady: state.codec.waitsForReady) {
                    sendChunks(&pending)
                } else if state.readyOverdue(timing.readyTimeout) {
                    readyTimedOut()
                }
            case .finish:
                let settled = await waitUntil(timing.readyTimeout) { self.state.ready || self.state.failed || self.state.lost }
                // 一直没就绪(也没收到错误):报告超时,让上层(听写结果、设置页「测试连接」)知道原因。
                if !settled, !Task.isCancelled, !state.failed {
                    report(CloudASRError.timeout(serviceName).localizedDescription)
                }
                if state.ready, !state.lost, !state.failed {
                    sendChunks(&pending)
                    state.markFinishing()
                    send((try? state.codec.finishMessages(lastChunk: pending)) ?? [])
                    pending.removeAll()
                    let completesOnFinal = state.codec.completesOnFinalAfterFinish
                    await waitUntil(timing.finishTimeout) {
                        self.state.completed || self.state.failed || self.state.lost
                            || (completesOnFinal && self.state.finalAfterFinish)
                    }
                }
                shutdown()
                return state.transcript()
            }
        }
        shutdown()
        return state.transcript()
    }

    /// 建立新连接:先让旧连接的回调失效(换代),再关闭旧连接。
    private func connect() {
        let codec = makeCodec()
        let old = state.connection
        let generation = state.reset(codec: codec)
        old?.close()
        do {
            let connection = try CloudConnection(request: codec.makeRequest()) { [weak self] message in
                self?.receive(message, generation: generation)
            } onClose: { [weak self] error in
                self?.connectionClosed(error, generation: generation)
            }
            state.setConnection(connection, generation: generation)
            send((try? codec.startMessages()) ?? [])
        } catch {
            report(error.localizedDescription)
        }
    }

    /// 按包大小发送,不足一包的留到下次(结束时由 finishMessages 带上)。
    private func sendChunks(_ pending: inout Data) {
        let size = state.codec.chunkBytes
        while pending.count >= size {
            let chunk = pending.prefix(size)
            pending.removeFirst(size)
            if let message = try? state.codec.audioMessage(Data(chunk)) { send([message]) }
        }
    }

    private func send(_ messages: [URLSessionWebSocketTask.Message]) {
        for message in messages { state.connection?.send(message) }
    }

    /// 轮询等待条件成立。返回条件是否成立(false = 超时或被取消)。
    @discardableResult
    private func waitUntil(_ timeout: Duration, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// 录音中连接迟迟不就绪:字幕(已经就绪过)当作断线去重连,其余情况报告超时。
    private func readyTimedOut() {
        let message = CloudASRError.timeout(serviceName).localizedDescription
        if purpose == .subtitles, state.everReady {
            Log.asr.notice("cloud stream not ready in time, reconnecting")
            state.markLost(message)
        } else {
            report(message)
        }
    }

    // MARK: - 接收端

    private func receive(_ message: URLSessionWebSocketTask.Message, generation: Int) {
        guard let events = state.parse(message, generation: generation) else { return }  // 旧连接的消息
        for event in events {
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
                    state.markLost(message)
                } else {
                    report(message)
                }
            }
        }
    }

    /// 连接关闭回调(每条连接最多一次)。旧连接、已经结束 / 已失败 / 已标记断开的连接都忽略(幂等)。
    private func connectionClosed(_ error: Error?, generation: Int) {
        guard state.isCurrent(generation), !state.closed, !state.finishing, !state.completed,
              !state.failed, !state.lost else { return }
        // 鉴权、额度类错误重连也没用:直接报告。
        if let error = error as? CloudASRError, error.isFatal {
            report(error.localizedDescription)
        } else if purpose == .subtitles, state.everReady {
            state.markLost(error?.localizedDescription)
        } else {
            // 听写 / 还没就绪过的字幕:连接断了就报告(服务端正常关闭也算,否则要等到超时才知道)。
            report(error?.localizedDescription ?? String(localized: "云端识别连接已断开", bundle: .l10n))
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
/// `generation` 标识当前连接:每次 `reset` 加一,旧连接的回调据此被忽略。
private nonisolated final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _codec: any RealtimeCodec = PlaceholderCodec()
    private var _connection: CloudConnection?
    private var generation = 0
    /// 当前连接建立的时间(判断就绪超时)。
    private var connectedAt = ContinuousClock.now
    private var finals: [String] = []
    private var partial = ""
    /// 最近一次断线 / 出错的原因(字幕重连放弃时报告它)。
    private var _lastError: String?
    private var flags = (ready: false, everReady: false, completed: false, failed: false, lost: false,
                         finishing: false, finalAfterFinish: false, closed: false)

    var codec: any RealtimeCodec { lock.withLock { _codec } }
    var connection: CloudConnection? { lock.withLock { _connection } }
    var lastError: String? { lock.withLock { _lastError } }
    var ready: Bool { lock.withLock { flags.ready } }
    var everReady: Bool { lock.withLock { flags.everReady } }
    var completed: Bool { lock.withLock { flags.completed } }
    var failed: Bool { lock.withLock { flags.failed } }
    var lost: Bool { lock.withLock { flags.lost } }
    var finishing: Bool { lock.withLock { flags.finishing } }
    var finalAfterFinish: Bool { lock.withLock { flags.finalAfterFinish } }
    var closed: Bool { lock.withLock { flags.closed } }

    /// 换一条新连接:清掉连接相关的标记,返回新的代号。
    func reset(codec: any RealtimeCodec) -> Int {
        lock.withLock {
            generation += 1
            _codec = codec
            _connection = nil
            connectedAt = .now
            flags.ready = false
            flags.lost = false
            flags.completed = false
            return generation
        }
    }

    func isCurrent(_ generation: Int) -> Bool { lock.withLock { self.generation == generation } }

    /// 记下新建的连接;期间又换了代(不应发生,保险起见)就直接关掉它。
    func setConnection(_ connection: CloudConnection, generation: Int) {
        let stale = lock.withLock { () -> Bool in
            guard self.generation == generation else { return true }
            _connection = connection
            return false
        }
        if stale { connection.close() }
    }

    func canSendAudio(waitsForReady: Bool) -> Bool {
        lock.withLock { !flags.lost && !flags.failed && (flags.ready || !waitsForReady) && _connection != nil }
    }

    /// 当前连接建立已超过 `timeout` 仍未就绪(且没有失败 / 断开)。
    func readyOverdue(_ timeout: Duration) -> Bool {
        lock.withLock {
            !flags.ready && !flags.failed && !flags.lost && !flags.closed && ContinuousClock.now - connectedAt > timeout
        }
    }

    /// 解析在接收线程上进行,用锁保护编解码器的去重状态。旧连接的消息返回 nil。
    func parse(_ message: URLSessionWebSocketTask.Message, generation: Int) -> [CodecEvent]? {
        lock.withLock {
            guard self.generation == generation else { return nil }
            return _codec.parse(message)
        }
    }

    func markReady() { lock.withLock { flags.ready = true; flags.everReady = true } }
    func markCompleted() { lock.withLock { flags.completed = true } }
    func markFailed() { lock.withLock { flags.failed = true } }
    func markLost(_ reason: String?) {
        lock.withLock {
            flags.lost = true
            if let reason { _lastError = reason }
        }
    }
    func markFinishing() { lock.withLock { flags.finishing = true } }
    func markClosed() { lock.withLock { flags.closed = true } }
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

    /// 主动关闭(可重复调用)。
    func close() {
        task.cancel(with: .normalClosure, reason: nil)
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

    /// 连接结束(主动关闭、收发出错、服务端关闭、握手失败都走这里),只处理第一次。
    /// URLSession 会强引用 delegate(也就是本对象),必须 invalidate 才能释放:出错断开时同样要做,否则每次重连都泄漏一条连接。
    private func finish(_ error: Error?) {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        if error != nil { task.cancel() }
        session.finishTasksAndInvalidate()
        onClose(error)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(closeCode == .normalClosure ? nil : CloudASRError.server(reason.map { String(decoding: $0, as: UTF8.self) } ?? "closed \(closeCode.rawValue)"))
    }

    /// 握手失败(如 401 / 403)在这里拿到 HTTP 状态码,给出可读的错误。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 101 {
            finish(CloudASRError.rejected(status: http.statusCode))
        } else if let error {
            finish(error)
        }
    }
}
