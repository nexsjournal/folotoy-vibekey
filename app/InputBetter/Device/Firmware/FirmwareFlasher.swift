import Foundation

/// 一键刷入 InputBetter 固件(app 不内置固件,刷写时从官网下载):
/// 1. 从官网获取固件清单,检查协议版本与 app 一致,下载镜像并校验 SHA-256(此时 USB 链路照常工作);
/// 2. 暂停 DeviceLink 的 USB 链路,让出串口;
/// 3. 读取设备 MAC;这台设备第一次刷写时先把整片 8 MB Flash 备份到本机(可用于恢复原固件);
/// 4. 只分段写 bootloader / 分区表 / 应用,绝不擦除整片,也不写受保护的 cardid 分区;
/// 5. 设备自动重启,恢复 USB 链路并重新握手。
/// 另外 `checkLatest()` 只查询官网最新固件(设置页显示「有新固件」用),不下载镜像。
@MainActor @Observable
final class FirmwareFlasher {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case preparing
        case backingUp(Double)
        case flashing(Double)
        case restarting
        case done(backup: String?)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .downloading, .preparing, .backingUp, .flashing, .restarting: true
            default: false
            }
        }
    }

    /// 官网最新固件的查询结果。
    enum Latest: Equatable {
        case unknown
        case checking
        case available(FirmwareManifest)
        /// 官网固件的协议版本与 app 不一致,需要先更新 app。
        case incompatible(FirmwareManifest)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var latest: Latest = .unknown
    /// app 内置的 esptool;缺失时不能刷写。
    let esptool: URL? = FirmwareFlasher.bundledEsptool()
    @ObservationIgnored private let link: DeviceLink
    @ObservationIgnored private let downloader: FirmwareDownloader
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var lastChecked: Date?
    /// 查询结果的有效期:设置页反复打开时不重复请求。
    private static let checkInterval: TimeInterval = 10 * 60

    /// 备份目录;同时认可 passport-keys 脚本留下的备份,避免重复备份。
    static let backupDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("InputBetter/Backups", isDirectory: true)
    private static let legacyBackupDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("esp/passport-backups")

    init(link: DeviceLink, downloader: FirmwareDownloader) {
        self.link = link
        self.downloader = downloader
    }

    /// 可以刷入的最新固件(协议兼容)。
    var latestManifest: FirmwareManifest? {
        if case .available(let manifest) = latest { return manifest }
        return nil
    }

    /// 查询官网最新固件。成功结果 10 分钟内有效;`force` 时立即重新查询。失败不影响刷写(刷写时会再请求一次)。
    func checkLatest(force: Bool = false) {
        guard checkTask == nil, !phase.isRunning else { return }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval, latestManifest != nil { return }
        latest = .checking
        checkTask = Task {
            defer { checkTask = nil }
            do {
                record(try await downloader.fetchManifest())
            } catch is CancellationError {
                latest = .unknown
            } catch {
                latest = .failed(error.localizedDescription)
            }
        }
    }

    /// 记下最新清单并返回它是否兼容。
    @discardableResult
    private func record(_ manifest: FirmwareManifest) -> Bool {
        lastChecked = Date()
        latest = manifest.isCompatible ? .available(manifest) : .incompatible(manifest)
        return manifest.isCompatible
    }

    func flash(port: String) {
        guard !phase.isRunning else { return }
        task = Task { await run(port: port) }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(port: String) async {
        do {
            guard let tool = esptool else { throw FirmwareError.toolMissing }
            // 下载阶段不占用串口,设备照常连接。
            phase = .downloading(0)
            checkTask?.cancel()
            let manifest = try await downloader.fetchManifest()
            guard record(manifest) else { throw FirmwareError.incompatible(manifest.version) }
            let images = try await downloader.download(manifest) { p in
                Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(p) } }
            }
            let backup = try await write(images, port: port, tool: tool)
            phase = .done(backup: backup?.path)
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 暂停 USB 链路后备份(仅首次)并写入镜像;返回新做的备份文件。
    private func write(_ images: [FirmwareDownloader.LocalImage], port: String, tool: URL) async throws -> URL? {
        phase = .preparing
        link.suspendUSB()
        defer { link.resumeUSB() }
        // 写入前再确认一次地址(清单解析时已校验,这里防止本机缓存被改动)。
        for image in images {
            let size = (try? FileManager.default.attributesOfItem(atPath: image.file.path)[.size] as? NSNumber)?.uint64Value ?? .max
            guard UInt64(image.offset) + size <= UInt64(FirmwareManifest.cardIDStart) else {
                throw FirmwareError.unsafeOffset(image.file.lastPathComponent)
            }
        }
        try await Task.sleep(for: .milliseconds(600))  // 等串口真正关闭

        let common = ["--chip", "esp32c3", "--port", port]
        let macResult = try await EsptoolRunner.run(tool, arguments: common + ["read-mac"])
        guard macResult.status == 0, let mac = EsptoolRunner.mac(in: macResult.output) else {
            throw FirmwareError.toolFailed(String(localized: "无法连接设备的下载模式：\(Self.lastLine(macResult.output))", bundle: .l10n))
        }

        let backup = try await ensureBackup(mac: mac, common: common, tool: tool)

        phase = .flashing(0)
        // 不传 flash 模式 / 频率 / 大小,esptool 默认保持 bootloader 镜像头里的值(keep);不加 --erase-all。
        var args = common + ["--baud", "921600", "--before", "default-reset", "--after", "hard-reset", "write-flash"]
        for image in images {
            args += [String(format: "0x%x", image.offset), image.file.path]
        }
        let result = try await EsptoolRunner.run(tool, arguments: args) { p in
            Task { @MainActor in self.phase = .flashing(p) }
        }
        guard result.status == 0 else { throw FirmwareError.toolFailed(String(localized: "写入失败：\(Self.lastLine(result.output))", bundle: .l10n)) }

        phase = .restarting
        try await Task.sleep(for: .seconds(2))
        return backup
    }

    /// app 内置的 esptool(scripts/bundle-device-assets.sh 打包进 Resources/DeviceAssets/Tools)。
    private static func bundledEsptool() -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("DeviceAssets/Tools/esptool"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// 返回新做的备份文件;已有备份时返回 nil。
    private func ensureBackup(mac: String, common: [String], tool: URL) async throws -> URL? {
        let name = "passport-\(mac)-flash.bin"
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.backupDir.appendingPathComponent(name).path)
            || fm.fileExists(atPath: Self.legacyBackupDir.appendingPathComponent(name).path) {
            return nil
        }
        try fm.createDirectory(at: Self.backupDir, withIntermediateDirectories: true)
        let target = Self.backupDir.appendingPathComponent(name)
        let partial = target.appendingPathExtension("partial")
        phase = .backingUp(0)
        let result = try await EsptoolRunner.run(tool, arguments: common + ["--baud", "921600", "read-flash", "0", "0x800000", partial.path]) { p in
            Task { @MainActor in self.phase = .backingUp(p) }
        }
        let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.intValue ?? 0
        guard result.status == 0, size == 0x800000 else {
            try? fm.removeItem(at: partial)
            throw FirmwareError.backupFailed(Self.lastLine(result.output))
        }
        try fm.moveItem(at: partial, to: target)
        return target
    }

    private static func lastLine(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? String(localized: "未知错误", bundle: .l10n)
    }
}
