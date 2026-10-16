import Foundation

/// app 内置的 Passport 固件与烧录工具(由 scripts/bundle-device-assets.sh 打包进 DeviceAssets 目录):
/// - `Firmware/manifest.json`:版本号、烧录参数、各镜像的写入地址;
/// - `Firmware/*.bin`:bootloader、分区表、应用;
/// - `Tools/esptool`:Espressif 官方独立版烧录工具(GPLv2,附 LICENSE)。
nonisolated struct FirmwareBundle: Sendable {
    struct Image: Sendable, Decodable {
        let offset: String
        let file: String
    }

    private struct Manifest: Decodable {
        let version: String
        let build: String?
        let flashArgs: [String]
        let images: [Image]
    }

    let version: String
    /// 构建标识(与设备 hello 上报的 build 同一算法),用于判断设备是否需要更新。
    var build: String? = nil
    let flashArgs: [String]
    let images: [(offset: UInt32, url: URL)]
    let esptool: URL

    /// 受保护的 cardid 分区起点:任何镜像都不能写到这里或之后。
    static let cardIDStart: UInt32 = 0x356000

    /// 读取内置资源;没有打包时返回 nil。
    static func load() -> FirmwareBundle? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("DeviceAssets"),
              let data = try? Data(contentsOf: root.appendingPathComponent("Firmware/manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        let esptool = root.appendingPathComponent("Tools/esptool")
        guard FileManager.default.isExecutableFile(atPath: esptool.path) else { return nil }
        var images: [(UInt32, URL)] = []
        for image in manifest.images {
            guard let offset = UInt32(image.offset.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return nil }
            images.append((offset, root.appendingPathComponent("Firmware/\(image.file)")))
        }
        return FirmwareBundle(version: manifest.version, build: manifest.build, flashArgs: manifest.flashArgs, images: images, esptool: esptool)
    }

    /// 校验所有镜像都存在,且写入范围都在 cardid 分区之前。
    func validate() throws {
        for (offset, url) in images {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber else {
                throw FirmwareError.missingImage(url.lastPathComponent)
            }
            if UInt64(offset) + size.uint64Value > UInt64(Self.cardIDStart) {
                throw FirmwareError.unsafeOffset(url.lastPathComponent)
            }
        }
    }
}

nonisolated enum FirmwareError: LocalizedError {
    case notBundled
    case missingImage(String)
    case unsafeOffset(String)
    case noPort
    case backupFailed(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .notBundled: String(localized: "app 里没有内置固件，请用 scripts/flash-firmware.sh 烧录", bundle: .l10n)
        case .missingImage(let f): String(localized: "固件文件缺失：\(f)", bundle: .l10n)
        case .unsafeOffset(let f): String(localized: "\(f) 的写入范围会覆盖受保护分区，已停止", bundle: .l10n)
        case .noPort: String(localized: "没有找到 USB 连接的 Passport", bundle: .l10n)
        case .backupFailed(let m): String(localized: "备份失败：\(m)", bundle: .l10n)
        case .toolFailed(let m): m
        }
    }
}
