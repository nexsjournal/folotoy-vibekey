import Foundation

/// 一键刷入 InputBetter 固件:
/// 1. 暂停 DeviceLink 的 USB 链路,让出串口;
/// 2. 读取设备 MAC;这台设备第一次刷写时先把整片 8 MB Flash 备份到本机(可用于恢复原固件);
/// 3. 只分段写 bootloader / 分区表 / 应用,绝不擦除整片,也不写受保护的 cardid 分区;
/// 4. 设备自动重启,恢复 USB 链路并重新握手。
@MainActor @Observable
final class FirmwareFlasher {
    enum Phase: Equatable {
        case idle
        case preparing
        case backingUp(Double)
        case flashing(Double)
        case restarting
        case done(backup: String?)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .preparing, .backingUp, .flashing, .restarting: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    let bundle = FirmwareBundle.load()
    @ObservationIgnored private let link: DeviceLink
    @ObservationIgnored private var task: Task<Void, Never>?

    /// 备份目录;同时认可 passport-keys 脚本留下的备份,避免重复备份。
    static let backupDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("InputBetter/Backups", isDirectory: true)
    private static let legacyBackupDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("esp/passport-backups")

    init(link: DeviceLink) {
        self.link = link
    }

    var bundledVersion: String? { bundle?.version }
    var bundledBuild: String? { bundle?.build }

    func flash(port: String) {
        guard !phase.isRunning else { return }
        task = Task { await run(port: port) }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(port: String) async {
        phase = .preparing
        link.suspendUSB()
        defer { link.resumeUSB() }
        do {
            guard let bundle else { throw FirmwareError.notBundled }
            try bundle.validate()
            try await Task.sleep(for: .milliseconds(600))  // 等串口真正关闭

            let common = ["--chip", "esp32c3", "--port", port]
            let macResult = try await EsptoolRunner.run(bundle.esptool, arguments: common + ["read-mac"])
            guard macResult.status == 0, let mac = EsptoolRunner.mac(in: macResult.output) else {
                throw FirmwareError.toolFailed(String(localized: "无法连接设备的下载模式：\(Self.lastLine(macResult.output))", bundle: .l10n))
            }

            let backup = try await ensureBackup(mac: mac, common: common, tool: bundle.esptool)

            phase = .flashing(0)
            var args = common + ["--baud", "921600", "--before", "default-reset", "--after", "hard-reset", "write-flash"]
            args += bundle.flashArgs
            for (offset, url) in bundle.images {
                args += [String(format: "0x%x", offset), url.path]
            }
            let result = try await EsptoolRunner.run(bundle.esptool, arguments: args) { p in
                Task { @MainActor in self.phase = .flashing(p) }
            }
            guard result.status == 0 else { throw FirmwareError.toolFailed(String(localized: "写入失败：\(Self.lastLine(result.output))", bundle: .l10n)) }

            phase = .restarting
            try await Task.sleep(for: .seconds(2))
            phase = .done(backup: backup?.path)
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
