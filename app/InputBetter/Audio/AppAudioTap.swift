import AppKit
import AVFoundation
import CoreAudio

/// 一个正在运行、可以采集声音的应用。
nonisolated struct AudioApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let pid: pid_t
    var isPlaying: Bool
    var id: String { bundleID }
}

/// Core Audio 进程音频对象的查询工具(macOS 14.2+ 的 process tap API)。
nonisolated enum AudioProcesses {
    struct Entry {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    static func all() -> [Entry] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            Entry(objectID: id,
                  pid: pid(of: id),
                  bundleID: CoreAudioQuery.string(id, kAudioProcessPropertyBundleID) ?? "",
                  isRunningOutput: uint32(id, kAudioProcessPropertyIsRunningOutput) != 0)
        }
    }

    /// 属于某个应用的所有音频进程。浏览器的声音来自 helper 子进程(Chrome 的
    /// `com.google.Chrome.helper`、Safari 的 `com.apple.WebKit.GPU`),所以同时按
    /// bundle ID 前缀和"负责进程"匹配。
    static func entries(for bundleID: String, in list: [Entry] = all()) -> [Entry] {
        let appPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        return list.filter { e in
            if e.bundleID == bundleID || e.bundleID.hasPrefix(bundleID + ".") { return true }
            if appPIDs.contains(e.pid) { return true }
            if let r = Responsibility.responsiblePID(for: e.pid), appPIDs.contains(r) { return true }
            return false
        }
    }

    /// 正在运行的普通应用,正在出声的排在前面。
    @MainActor static func runningApps() -> [AudioApp] {
        let list = all()
        let me = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != me
        }
        return apps.map { app in
            let bid = app.bundleIdentifier!
            let playing = entries(for: bid, in: list).contains { $0.isRunningOutput }
            return AudioApp(bundleID: bid, name: app.localizedName ?? bid, pid: app.processIdentifier, isPlaying: playing)
        }
        .sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func pid(of id: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid)
        return pid
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }
}

/// `responsibility_get_pid_responsible_for_pid` 是 libSystem 里未公开的函数,
/// 用它把 WebKit GPU 进程等 XPC 服务归到 Safari 等宿主应用。拿不到时退回前缀匹配。
nonisolated enum Responsibility {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn, pid > 0 else { return nil }
        let r = fn(pid)
        return r > 0 && r != pid ? r : nil
    }
}

/// 采集指定应用的声音:为它的所有音频进程创建 process tap,包进私有聚合设备,
/// 在 IOProc 里转成 16 kHz 单声道。应用新开音频进程时(例如网页开始播放)自动重建。
nonisolated final class AppAudioTap: AudioSource, @unchecked Sendable {
    var onSamples: (@Sendable ([Float]) -> Void)?
    let bundleID: String

    /// 控制队列:建/拆 tap、监听进程列表。IOProc 在单独的 ioQueue 上,避免拆除时互相等待。
    private let queue = DispatchQueue(label: "InputBetter.tap.control")
    private let ioQueue = DispatchQueue(label: "InputBetter.tap.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedObjects: Set<AudioObjectID> = []
    private var format: AVAudioFormat?
    private let converter = AudioConverter()
    private var listener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(bundleID: String) {
        self.bundleID = bundleID
    }

    func start() throws {
        try queue.sync {
            running = true
            try rebuild(force: true)
            installListener()
        }
    }

    func stop() {
        queue.sync {
            running = false
            removeListener()
            teardown()
        }
    }

    deinit {
        removeListener()
        teardown()
    }

    // MARK: - Tap 生命周期(都在 queue 上执行)

    private func rebuild(force: Bool) throws {
        let objects = Set(AudioProcesses.entries(for: bundleID).map(\.objectID))
        if !force, objects == tappedObjects { return }
        teardown()
        tappedObjects = objects
        guard !objects.isEmpty else {
            // 应用还没有音频进程,等进程列表变化后再建。
            Log.audio.info("tap: no audio process yet for \(self.bundleID, privacy: .public)")
            return
        }

        let description = CATapDescription(stereoMixdownOfProcesses: Array(objects))
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "InputBetter Tap"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else { throw tapError(String(localized: "创建音频 tap 失败", bundle: .l10n), err) }
        tapID = tap

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard err == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { throw tapError(String(localized: "读取 tap 格式失败", bundle: .l10n), err) }
        format = fmt

        let outputUID = CoreAudioQuery.defaultOutputDevice().flatMap { CoreAudioQuery.string($0, kAudioDevicePropertyDeviceUID) } ?? ""
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "InputBetter Tap",
            kAudioAggregateDeviceUIDKey: "InputBetter-Tap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else { throw tapError(String(localized: "创建聚合设备失败", bundle: .l10n), err) }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard err == noErr, let proc else { throw tapError(String(localized: "创建 IOProc 失败", bundle: .l10n), err) }
        procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { throw tapError(String(localized: "启动采集失败", bundle: .l10n), err) }
        Log.audio.info("tap started for \(self.bundleID, privacy: .public): \(objects.count, privacy: .public) process(es), \(fmt.sampleRate, privacy: .public) Hz")
    }

    private func handle(_ list: UnsafePointer<AudioBufferList>) {
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
        let samples = converter.convert(buffer)
        if !samples.isEmpty { onSamples?(samples) }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedObjects = []
    }

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            do { try self.rebuild(force: false) } catch {
                Log.audio.error("tap rebuild failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    private func removeListener() {
        guard let listener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        self.listener = nil
    }

    private func tapError(_ message: String, _ status: OSStatus) -> NSError {
        NSError(domain: "InputBetter.Tap", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(message)(\(status))"])
    }
}
