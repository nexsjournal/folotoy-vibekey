import Foundation
import Observation
import os

// MARK: - DeviceLink

/// 发现并连接 Passport,收发 docs/protocol.md 定义的消息。
///
/// - USB 优先:有 Espressif 串口时先握手;USB 握手成功后断开蓝牙,USB 断开后回到蓝牙扫描。
/// - 握手:`hello` 最多发 6 次、间隔 800 ms;成功后先重发缓存的 config / state(以及 mic),再回调 `onConnectionChange`。
/// - 心跳:每 5 秒 `ping`;16 秒没收到任何有效消息即断开重连;每 5 分钟重发 config 校准时钟。
/// - 按键按 `(boot, seq)` 去重;麦克风 ADPCM 在后台串行队列上解码后交给 `onMicSamples`。
///
/// 所有状态只在主线程修改。
@MainActor @Observable final class DeviceLink {
    enum Connection: Equatable { case disconnected, usb, ble }

    private(set) var connection: Connection = .disconnected
    /// 0...100;未知时为 nil。
    private(set) var batteryPercent: Int?
    private(set) var charging = false
    private(set) var firmwareVersion: String?
    /// 固件构建标识,用来判断设备是否运行 app 内置的同一份固件。
    private(set) var firmwareBuild: String?
    /// 最近一次按键(引导页的"按键测试"据此高亮对应的键);`id` 每次递增,便于界面察觉重复按同一个键。
    private(set) var lastKey: (id: Int, key: DeviceKey, event: DeviceKeyEvent)?
    /// 通过 USB 发现了 Passport(Espressif 串口),但它运行的不是 InputBetter 固件;引导页据此提示刷固件。
    private(set) var foreignDevice: ForeignDevice?
    private(set) var lastError: String? {
        didSet {
            if let lastError, lastError != oldValue {
                DeviceLog.link.error("\(lastError, privacy: .public)")
            }
        }
    }

    /// 用户设置:为 false 时完全不使用蓝牙,也不会创建 CBCentralManager(不触发蓝牙授权)。
    var bluetoothEnabled: Bool = true {
        didSet {
            if bluetoothEnabled != oldValue { updateBluetooth() }
        }
    }

    /// 按键事件,主线程调用,已去重。第三个参数为 ack:这次按压用于关闭设备上的 agent 通知,
    /// 上层应忽略它的常规动作(设备仍会上报 down/up/long)。
    @ObservationIgnored var onKey: ((DeviceKey, DeviceKeyEvent, Bool) -> Void)?
    /// 连接状态变化,主线程调用。连上时 config / state 已经重发过。
    @ObservationIgnored var onConnectionChange: ((Connection) -> Void)?
    /// 16 kHz 单声道 float 样本,在后台串行队列上调用。
    @ObservationIgnored var onMicSamples: (@Sendable ([Float]) -> Void)? {
        didSet { mic.setHandler(onMicSamples) }
    }

    private static let handshakeAttempts = 6
    private static let handshakeInterval: Duration = .milliseconds(800)
    private static let pingInterval: Duration = .seconds(5)
    private static let staleTimeout: TimeInterval = 16
    private static let configResendInterval: TimeInterval = 300
    private static let levelInterval: TimeInterval = 0.05
    /// 串口节点刚出现时设备可能仍在枚举,稍等再打开。
    private static let usbOpenDelay: Duration = .milliseconds(300)
    private static let usbRetryDelay: Duration = .seconds(1)
    private static let usbBusyRetryDelay: Duration = .seconds(3)

    private let monitor = SerialDeviceMonitor()
    private let ble = BLEClient()
    private let mic = MicStream()

    @ObservationIgnored private var running = false
    /// 已握手并作为当前连接的链路。
    @ObservationIgnored private var active: DeviceLinkKind?

    // USB
    @ObservationIgnored private var ports: [SerialPortInfo] = []
    /// 握手失败的端口(多半是刷了其它固件的 ESP32 板子),拔掉后忘记。
    @ObservationIgnored private var rejectedPorts: Set<String> = []
    /// 打开失败(被占用)的端口,期间允许蓝牙。
    @ObservationIgnored private var busyPorts: Set<String> = []
    @ObservationIgnored private var usb: USBSession?
    @ObservationIgnored private var usbSessionCounter = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?

    // BLE
    /// Events 通知已开启(onReady 与 onDisconnected 之间)。
    @ObservationIgnored private var bleSessionUp = false
    @ObservationIgnored private var bleHandshaken = false
    @ObservationIgnored private var bleDecoder = StreamDecoder()

    // 公共
    @ObservationIgnored private var handshakeTasks: [DeviceLinkKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastMessageAt: [DeviceLinkKind: TimeInterval] = [:]
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var filter = RecentEventFilter()
    @ObservationIgnored private var lastConfig: DeviceConfig?
    @ObservationIgnored private var lastConfigSentAt: TimeInterval = -.infinity
    @ObservationIgnored private var lastState: CachedState?
    /// 最近一次按键提示(已转 ASCII 截断),握手后补发;未变化时不重复发送。
    @ObservationIgnored private var lastKeyHints: KeyHints?
    @ObservationIgnored private var micWanted = false
    @ObservationIgnored private var lastLevelSentAt: TimeInterval = -.infinity

    private struct KeyHints: Equatable {
        var ok: String
        var up: String
        var down: String

        var command: HostCommand { .keys(ok: ok, up: up, down: down) }
    }

    private struct CachedState {
        var st: DeviceUIState
        var mode: DeviceMode
        var msg: String
    }

    /// 运行其他固件的设备。
    struct ForeignDevice: Equatable {
        let path: String
        /// 设备自报的固件名;不应答握手时为 nil(出厂固件或其它程序)。
        let firmware: String?
    }

    /// 刷固件期间暂停 USB,让出串口。
    private var usbSuspended = false
    /// 握手失败前收到的固件名,用于填充 `foreignDevice`。
    private var pendingForeignFirmware: String?

    init() {}

    // MARK: 公开接口

    /// 开始监听 USB 串口并(按设置)扫描蓝牙;重复调用无效。
    func start() {
        guard !running else { return }
        running = true
        lastError = nil

        monitor.onChange = { [weak self] ports in
            self?.portsChanged(ports)
        }
        ble.onStateChange = { [weak self] state in
            self?.bluetoothStateChanged(state)
        }
        ble.onReady = { [weak self] name in
            self?.bluetoothReady(name)
        }
        ble.onData = { [weak self] data in
            self?.receiveBluetooth(data)
        }
        ble.onAudioData = { [weak self] data in
            self?.receiveBluetoothAudio(data)
        }
        ble.onDisconnected = { [weak self] in
            self?.bluetoothDisconnected()
        }

        monitor.start()
        updateBluetooth()
        updateAudioSubscription()

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled else { return }
                self?.heartbeat()
            }
        }
        DeviceLog.link.info("device link started")
    }

    /// 已通过 USB 握手的串口路径(刷固件时使用);蓝牙连接或未连接时为 nil。
    var usbPortPath: String? {
        usb?.handshaken == true ? usb?.path : nil
    }

    /// 暂停 USB 链路并释放串口(刷固件前调用)。
    func suspendUSB() {
        usbSuspended = true
        openTask?.cancel()
        closeUSB(reopen: false)
    }

    /// 恢复 USB 链路:清空拒绝列表,重新尝试握手(刷完固件后调用)。
    func resumeUSB() {
        usbSuspended = false
        rejectedPorts.removeAll()
        foreignDevice = nil
        scheduleUSBOpen(after: Self.usbOpenDelay)
    }

    /// 发 `bye` 后关闭所有链路。
    func stop() {
        guard running else { return }
        let bye = HostCommand.bye.data
        running = false

        heartbeatTask?.cancel()
        heartbeatTask = nil
        openTask?.cancel()
        openTask = nil
        handshakeTasks.values.forEach { $0.cancel() }
        handshakeTasks.removeAll()
        monitor.stop()
        monitor.onChange = nil

        if let session = usb {
            usb = nil
            if session.handshaken {
                session.port.writeAndClose(bye)
            } else {
                session.port.close()
            }
        }
        if bleHandshaken {
            ble.send(bye)
            ble.disable(after: .milliseconds(250))
        } else {
            ble.setEnabled(false)
        }
        bleHandshaken = false
        bleSessionUp = false
        bleDecoder.reset()
        mic.resetBLE()
        lastMessageAt.removeAll()
        setActive(nil)
        DeviceLog.link.info("device link stopped")
    }

    /// 缓存并下发界面状态;未连接时只缓存,握手后自动补发。`msg` 会转 ASCII 并截到 23 字节。
    func sendState(_ st: DeviceUIState, mode: DeviceMode, msg: String = "") {
        lastState = CachedState(st: st, mode: mode, msg: msg)
        send(.state(st, mode: mode, msg: msg))
    }

    /// 缓存并下发屏幕底部三个键的提示文字(各转 ASCII、截到 11 字节;空字符串表示该键无动作)。
    /// 与上次相同时不发送;未连接时只缓存,握手后自动补发。
    /// 右侧三个键的提示图标;nil 表示该键当前无动作(隐藏提示)。
    func sendKeyHints(ok: DeviceIcon?, up: DeviceIcon?, down: DeviceIcon?) {
        sendKeyHints(ok: ok?.rawValue ?? "", up: up?.rawValue ?? "", down: down?.rawValue ?? "")
    }

    private func sendKeyHints(ok: String, up: String, down: String) {
        let max = HostCommand.keyHintMaxBytes
        let hints = KeyHints(
            ok: DeviceText.ascii(ok, maxBytes: max),
            up: DeviceText.ascii(up, maxBytes: max),
            down: DeviceText.ascii(down, maxBytes: max)
        )
        guard hints != lastKeyHints else { return }
        lastKeyHints = hints
        send(hints.command)
    }

    /// 下发编程 Agent 通知(不缓存:断线期间的通知不补发)。`msg` 为来源名,转 ASCII 并截到 23 字节。
    /// 列表页:按选中项计算可见窗口(一屏 6 行),发送 `list` 命令。不缓存,断线后由上层重新发送。
    func sendList(title: String, items: [String], selected: Int) {
        let top = HostCommand.listTop(total: items.count, selected: selected)
        let visible = Array(items.dropFirst(top).prefix(HostCommand.listVisibleRows))
        send(.list(title: title, sel: selected, total: items.count, top: top, items: visible))
    }

    func sendAgent(_ ev: DeviceAgentEvent, msg: String) {
        send(.agent(ev, msg: msg))
    }

    /// 0...100,内部限流到每 50 ms 最多一次;未连接时直接丢弃。
    func sendLevel(_ v: Int) {
        guard active != nil else { return }
        let now = Self.now
        guard now - lastLevelSentAt >= Self.levelInterval else { return }
        lastLevelSentAt = now
        send(.level(v))
    }

    /// 缓存并下发设置;附带 `clock`,连接期间每 5 分钟自动重发。
    func sendConfig(_ c: DeviceConfig) {
        lastConfig = c
        updateAudioSubscription()
        guard let active else { return }
        writeConfig(c, via: active)
    }

    /// 开 / 关麦克风上行,同时订阅 / 取消蓝牙 Audio In 通知。
    func setMic(_ on: Bool) {
        micWanted = on
        updateAudioSubscription()
        send(.mic(on))
    }

    // MARK: 发送

    /// 发到当前已连接的链路;未连接时丢弃。
    private func send(_ command: HostCommand) {
        guard let active else { return }
        write(command, via: active)
    }

    /// 发到指定链路(握手阶段链路还不是 active,所以需要显式指定)。
    private func write(_ command: HostCommand, via link: DeviceLinkKind) {
        let data = command.data
        switch link {
        case .usb: usb?.port.write(data)
        case .ble: ble.send(data)
        }
    }

    /// 下发 config 并附带当前本地时间,记录发送时刻供 5 分钟重发判断。
    private func writeConfig(_ c: DeviceConfig, via link: DeviceLinkKind) {
        lastConfigSentAt = Self.now
        write(.config(c, clock: HostCommand.localClock()), via: link)
    }

    /// 听写音源是 Passport 麦克风时,设备在 OK 按下瞬间就开始推音频,所以那时也要保持 Audio In 订阅。
    private func updateAudioSubscription() {
        ble.setAudioInputEnabled(micWanted || lastConfig?.passportMic == true)
    }

    // MARK: 链路状态

    /// 该链路是否已完成 hello 握手。
    private func isHandshaken(_ link: DeviceLinkKind) -> Bool {
        switch link {
        case .usb: usb?.handshaken == true
        case .ble: bleHandshaken
        }
    }

    /// 切换当前连接链路,同步 `connection` 与麦克风过滤;连接状态真正变化时才回调 `onConnectionChange`。
    private func setActive(_ link: DeviceLinkKind?) {
        active = link
        mic.setActive(link)
        let newConnection: Connection = switch link {
        case .usb: .usb
        case .ble: .ble
        case nil: .disconnected
        }
        guard newConnection != connection else { return }
        connection = newConnection
        lastLevelSentAt = -.infinity
        if newConnection == .disconnected {
            batteryPercent = nil
            charging = false
            firmwareVersion = nil
        }
        DeviceLog.link.info("connection: \(String(describing: newConnection), privacy: .public)")
        onConnectionChange?(newConnection)
    }

    /// 某条链路断开或失效。
    private func linkLost(_ link: DeviceLinkKind) {
        handshakeTasks[link]?.cancel()
        handshakeTasks[link] = nil
        lastMessageAt[link] = nil
        switch link {
        case .usb: usb?.handshaken = false
        case .ble: bleHandshaken = false
        }
        if active == link {
            setActive(nil)
        }
    }

    /// 链路可用后开始握手:每 800 ms 发一次 hello,共 6 次;收到 hello 时由 handleHello 取消该任务。
    private func beginHandshake(_ link: DeviceLinkKind) {
        lastMessageAt[link] = Self.now
        handshakeTasks[link]?.cancel()
        handshakeTasks[link] = Task { [weak self] in
            for _ in 0..<Self.handshakeAttempts {
                guard !Task.isCancelled else { return }
                self?.write(.hello, via: link)
                try? await Task.sleep(for: Self.handshakeInterval)
            }
            guard !Task.isCancelled else { return }
            self?.handshakeFailed(link, reason: String(localized: "设备未应答握手", bundle: .l10n))
        }
    }

    /// 握手失败:USB 端口记入拒绝列表(拔掉后忘记)并尝试下一个端口;蓝牙断开后由 BLEClient 稍后重扫。
    private func handshakeFailed(_ link: DeviceLinkKind, reason: String) {
        handshakeTasks[link]?.cancel()
        handshakeTasks[link] = nil
        switch link {
        case .usb:
            guard let session = usb else { return }
            // 同一 VID 的其它 ESP32 板子很常见,只记日志不报错;拔掉后会忘掉这个记录。
            DeviceLog.link.notice("USB \(session.path, privacy: .public): \(reason, privacy: .public), ignoring port")
            foreignDevice = ForeignDevice(path: session.path, firmware: pendingForeignFirmware)
            pendingForeignFirmware = nil
            rejectedPorts.insert(session.path)
            closeUSB(reopen: true)
        case .ble:
            guard bleSessionUp else { return }
            lastError = String(localized: "蓝牙：\(reason)", bundle: .l10n)
            linkLost(.ble)
            ble.disconnect()
        }
    }

    /// 每 5 秒执行:对已握手的链路做超时检测并发 ping,到期重发 config 校准时钟。
    private func heartbeat() {
        guard running else { return }
        let now = Self.now
        for link in [DeviceLinkKind.usb, .ble] where isHandshaken(link) {
            if now - (lastMessageAt[link] ?? now) > Self.staleTimeout {
                // 链路还在但设备不再应答(固件卡住或蓝牙假连接),断开后重新发现。
                lastError = String(localized: "设备无响应，正在重新连接", bundle: .l10n)
                switch link {
                case .usb:
                    closeUSB(reopen: true)
                case .ble:
                    linkLost(.ble)
                    ble.disconnect()
                }
                continue
            }
            write(.ping, via: link)
        }
        if let active, let config = lastConfig, now - lastConfigSentAt >= Self.configResendInterval {
            writeConfig(config, via: active)
        }
    }

    // MARK: 接收

    /// 处理一条已解析的设备消息(主线程)。任何有效消息都刷新该链路的最后活跃时间。
    private func handle(_ message: DeviceMessage, via link: DeviceLinkKind) {
        guard running else { return }
        lastMessageAt[link] = Self.now

        switch message {
        case .hello(let hello):
            handleHello(hello, via: link)
        case .key(let report):
            guard isHandshaken(link) else { return }
            guard filter.accept(report) else {
                DeviceLog.link.debug("duplicate key seq=\(report.seq ?? -1) via \(link.rawValue, privacy: .public)")
                return
            }
            DeviceLog.link.info("key \(report.key.rawValue, privacy: .public) \(report.event.rawValue, privacy: .public)\(report.ack ? " ack" : "", privacy: .public) seq=\(report.seq ?? -1) via \(link.rawValue, privacy: .public)")
            lastKey = ((lastKey?.id ?? 0) + 1, report.key, report.event)
            onKey?(report.key, report.event, report.ack)
        case .battery(let report):
            guard link == active else { return }
            batteryPercent = report.percent
            charging = report.charging
        case .pong:
            break
        }
    }

    /// 握手成功:校验固件名,补发缓存的 config / state / mic,再切换当前链路并通知上层;USB 成功时让蓝牙让位。
    private func handleHello(_ hello: DeviceHello, via link: DeviceLinkKind) {
        guard hello.firmware == DeviceMessage.firmwareName else {
            if link == .usb { pendingForeignFirmware = hello.firmware }
            handshakeFailed(link, reason: String(localized: "不是 InputBetter 固件（\(hello.firmware)）", bundle: .l10n))
            return
        }
        // 握手重试期间设备可能回多个 hello,只处理第一个。
        guard !isHandshaken(link) else { return }
        handshakeTasks[link]?.cancel()
        handshakeTasks[link] = nil

        if link == .usb { foreignDevice = nil }
        switch link {
        case .usb:
            usb?.handshaken = true
        case .ble:
            guard usb?.handshaken != true else {
                // USB 已经在线,蓝牙让位。
                updateBluetooth()
                return
            }
            bleHandshaken = true
        }

        if hello.protocolVersion != DeviceMessage.protocolVersion {
            DeviceLog.link.notice("firmware protocol \(hello.protocolVersion), app speaks \(DeviceMessage.protocolVersion)")
        }
        DeviceLog.link.info("hello via \(link.rawValue, privacy: .public): ver=\(hello.version, privacy: .public) boot=\(hello.boot, privacy: .public)")
        firmwareVersion = hello.version.isEmpty ? nil : hello.version
        firmwareBuild = hello.build.isEmpty ? nil : hello.build
        lastError = nil

        // 设备不保存这些状态,每次握手后先下发(config、state、按键提示、mic),再通知上层。
        if let config = lastConfig {
            writeConfig(config, via: link)
        }
        if let state = lastState {
            write(.state(state.st, mode: state.mode, msg: state.msg), via: link)
        }
        if let hints = lastKeyHints {
            write(hints.command, via: link)
        }
        if micWanted {
            write(.mic(true), via: link)
        }

        setActive(link)
        if link == .usb {
            // USB 优先:握手成功后断开蓝牙(不发 bye,设备仍通过 USB 在线)。
            updateBluetooth()
        }
    }

    // MARK: USB

    /// Espressif 串口集合变化:忘掉已消失端口的记录,当前端口消失则关闭会话,然后稍后尝试打开。
    private func portsChanged(_ newPorts: [SerialPortInfo]) {
        ports = newPorts
        let paths = Set(newPorts.map(\.path))
        rejectedPorts.formIntersection(paths)
        if let foreign = foreignDevice, !paths.contains(foreign.path) { foreignDevice = nil }
        busyPorts.formIntersection(paths)
        if let usb, !paths.contains(usb.path) {
            closeUSB(reopen: false)
        }
        updateBluetooth()
        scheduleUSBOpen(after: Self.usbOpenDelay)
    }

    /// 延迟尝试打开下一个 USB 端口;新的调度会取消旧的。
    private func scheduleUSBOpen(after delay: Duration) {
        openTask?.cancel()
        openTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.openNextUSBPort()
        }
    }

    /// 打开第一个未被拒绝的端口(优先未被占用的)并开始握手。串口回调在串口队列上解帧,消息切回主线程。
    private func openNextUSBPort() {
        guard running, usb == nil, !usbSuspended else { return }
        let candidates = ports.filter { !rejectedPorts.contains($0.path) }
        guard let candidate = candidates.first(where: { !busyPorts.contains($0.path) }) ?? candidates.first else {
            updateBluetooth()
            return
        }
        let path = candidate.path
        usbSessionCounter += 1
        let sessionID = usbSessionCounter
        let pump = USBStreamPump(frames: mic)
        do {
            let port = try SerialPort(
                path: path,
                onData: { [weak self] data in
                    // 串口队列上解帧:音频直接交给麦克风队列,协议消息切回主线程。
                    let messages = pump.feed(data)
                    guard !messages.isEmpty else { return }
                    DispatchQueue.main.async {
                        self?.receiveUSB(messages, session: sessionID)
                    }
                },
                onClose: { [weak self] code in
                    DispatchQueue.main.async {
                        self?.usbPortClosed(session: sessionID, code: code)
                    }
                }
            )
            usb = USBSession(id: sessionID, path: path, port: port)
            busyPorts.remove(path)
            DeviceLog.link.info("USB opened \(path, privacy: .public)")
            updateBluetooth()
            beginHandshake(.usb)
        } catch {
            // 端口被占用(例如 idf.py monitor)时先允许蓝牙,稍后重试。
            busyPorts.insert(path)
            lastError = error.localizedDescription
            updateBluetooth()
            scheduleUSBOpen(after: Self.usbBusyRetryDelay)
        }
    }

    /// 主线程处理 USB 消息;session 不匹配说明来自已关闭的旧会话,丢弃。
    private func receiveUSB(_ messages: [DeviceMessage], session: Int) {
        guard let usb, usb.id == session else { return }
        for message in messages {
            handle(message, via: .usb)
        }
    }

    /// 串口被动关闭(拔线、设备复位、I/O 错误):稍后重新打开。
    private func usbPortClosed(session: Int, code: Int32?) {
        guard let usb, usb.id == session else { return }
        if let code, usb.handshaken {
            lastError = String(localized: "USB 连接中断：\(String(cString: strerror(code)))", bundle: .l10n)
        }
        closeUSB(reopen: true)
    }

    /// 关闭当前 USB 会话并标记链路断开;`reopen` 为 true 时 1 秒后重新尝试打开。
    private func closeUSB(reopen: Bool) {
        guard let session = usb else { return }
        usb = nil
        session.port.close()
        linkLost(.usb)
        updateBluetooth()
        if reopen, running {
            scheduleUSBOpen(after: Self.usbRetryDelay)
        }
    }

    // MARK: Bluetooth

    /// USB 已握手时关闭蓝牙;存在待握手的 USB 端口时不新建蓝牙连接(已有蓝牙连接则保留,直到 USB 握手成功)。
    private func updateBluetooth() {
        let usbConnected = usb?.handshaken == true
        let usbPending = usb != nil
            || ports.contains { !rejectedPorts.contains($0.path) && !busyPorts.contains($0.path) }
        let want = running && bluetoothEnabled && !usbConnected && (bleSessionUp || !usbPending)
        if want {
            ble.setEnabled(true)
        } else if bleHandshaken && !usbConnected {
            // 用户关掉了蓝牙:先告诉设备 Mac 离线,稍等再断开。
            write(.bye, via: .ble)
            bleSessionUp = false
            linkLost(.ble)
            ble.disable(after: .milliseconds(250))
        } else {
            ble.setEnabled(false)
        }
    }

    /// 蓝牙适配器 / 权限状态变化,只用于给出 lastError 提示。
    private func bluetoothStateChanged(_ state: BLEClient.State) {
        DeviceLog.link.info("bluetooth: \(String(describing: state), privacy: .public)")
        switch state {
        case .unauthorized:
            lastError = String(localized: "未获得蓝牙权限，可在 系统设置 > 隐私与安全性 > 蓝牙 中允许 InputBetter", bundle: .l10n)
        case .poweredOff:
            if connection == .disconnected { lastError = String(localized: "蓝牙已关闭", bundle: .l10n) }
        case .unsupported:
            if connection == .disconnected { lastError = String(localized: "此 Mac 不支持低功耗蓝牙", bundle: .l10n) }
        default:
            break
        }
    }

    /// BLE Events 通知已开启:USB 已在线时让位,否则开始握手。
    private func bluetoothReady(_ name: String) {
        guard running, bluetoothEnabled, usb?.handshaken != true else {
            updateBluetooth()
            return
        }
        DeviceLog.link.info("BLE ready: \(name, privacy: .public)")
        bleSessionUp = true
        bleHandshaken = false
        bleDecoder.reset()
        mic.resetBLE()
        beginHandshake(.ble)
    }

    /// BLE Events 通知的原始字节(可能半行),按行重新组帧后处理。
    private func receiveBluetooth(_ data: Data) {
        guard bleSessionUp else { return }
        for item in bleDecoder.feed(data) {
            switch item {
            case .line(let line):
                if let message = DeviceMessage.parse(line) {
                    handle(message, via: .ble)
                }
            case .frame(let type, let seq, let payload):
                mic.receiveFrame(type: type, seq: seq, payload: payload, from: .ble)
            }
        }
    }

    /// BLE Audio In 通知,直接转给麦克风队列拼帧解码。
    private func receiveBluetoothAudio(_ data: Data) {
        guard bleSessionUp else { return }
        mic.receiveBLEAudio(data)
    }

    /// BLE 外设断开:丢弃半行 / 半帧,标记链路断开,并重新评估是否继续用蓝牙。
    private func bluetoothDisconnected() {
        bleSessionUp = false
        bleDecoder.reset()
        mic.resetBLE()
        linkLost(.ble)
        updateBluetooth()
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

// MARK: - 辅助类型

/// 一次 USB 串口会话:端口、握手状态和会话编号(用来丢弃旧会话迟到的回调)。只在主线程访问。
private final class USBSession {
    let id: Int
    let path: String
    let port: SerialPort
    var handshaken = false

    init(id: Int, path: String, port: SerialPort) {
        self.id = id
        self.path = path
        self.port = port
    }
}
