import Foundation

/// 官网发布的 Passport 固件清单(`https://input.0os.io/firmware/manifest.json`,由 scripts/package-firmware.sh 生成)。
/// app 和官网的网页刷写读的是同一份清单。
///
/// 清单来自网络,只当作数据:
/// - 不带任何 esptool 参数,app 只按清单里的地址分段写入,写入命令由 `FirmwareFlasher` 自己拼;
/// - 每个镜像的写入范围必须落在受保护的 cardid 分区之前;
/// - 镜像路径只能是清单所在目录下的相对路径;
/// - 每个镜像都带大小和 SHA-256,下载后逐个校验(见 `FirmwareDownloader`)。
nonisolated struct FirmwareManifest: Sendable, Decodable, Equatable {
    struct Image: Sendable, Decodable, Equatable {
        /// 写入地址,十六进制字符串,例如 "0x10000"。
        let offset: String
        /// 相对清单的路径,例如 "0.1.0-b96b1ea2/app.bin"。
        let path: String
        let size: Int
        let sha256: String
    }

    /// 校验通过、可以直接下载和写入的镜像。
    struct Part: Sendable, Equatable {
        let offset: UInt32
        let url: URL
        let size: Int
        /// 小写十六进制。
        let sha256: String
        var fileName: String { url.lastPathComponent }
    }

    let version: String
    /// 构建标识(与设备 hello 上报的 build 同一算法),用于判断设备是否需要更新。
    let build: String
    /// 固件使用的协议版本,必须与 app 一致才能刷(见 `isCompatible`)。
    let proto: Int
    let chip: String
    let images: [Image]

    /// 受保护的 cardid 分区起点:任何镜像都不能写到这里或之后。
    static let cardIDStart: UInt32 = 0x356000
    static let supportedChip = "ESP32-C3"

    /// 固件协议与当前 app 一致。官网固件更新了协议而 app 还是旧版时,提示用户先更新 app。
    var isCompatible: Bool { proto == DeviceMessage.protocolVersion }

    /// 校验清单并解析出每个镜像的写入地址与下载地址;任何一项不合规都整体拒绝。
    func parts(relativeTo manifestURL: URL) throws -> [Part] {
        guard chip == Self.supportedChip else { throw FirmwareError.badManifest(String(localized: "芯片型号不是 \(Self.supportedChip)", bundle: .l10n)) }
        guard !images.isEmpty else { throw FirmwareError.badManifest(String(localized: "没有固件镜像", bundle: .l10n)) }
        var parts: [Part] = []
        for image in images {
            guard let offset = Self.parseOffset(image.offset) else {
                throw FirmwareError.badManifest(String(localized: "写入地址无效：\(image.offset)", bundle: .l10n))
            }
            guard image.size > 0, UInt64(offset) + UInt64(image.size) <= UInt64(Self.cardIDStart) else {
                throw FirmwareError.unsafeOffset(image.path)
            }
            guard let url = Self.resolve(image.path, relativeTo: manifestURL) else {
                throw FirmwareError.badManifest(String(localized: "镜像路径无效：\(image.path)", bundle: .l10n))
            }
            let sha = image.sha256.lowercased()
            guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else {
                throw FirmwareError.badManifest(String(localized: "校验值无效：\(image.path)", bundle: .l10n))
            }
            parts.append(Part(offset: offset, url: url, size: image.size, sha256: sha))
        }
        // 镜像之间不能重叠,否则后写的会覆盖先写的。
        let sorted = parts.sorted { $0.offset < $1.offset }
        for (a, b) in zip(sorted, sorted.dropFirst()) where UInt64(a.offset) + UInt64(a.size) > UInt64(b.offset) {
            throw FirmwareError.badManifest(String(localized: "镜像写入范围重叠：\(a.fileName)、\(b.fileName)", bundle: .l10n))
        }
        return parts
    }

    static func parseOffset(_ text: String) -> UInt32? {
        let lower = text.lowercased()
        guard lower.hasPrefix("0x") else { return nil }
        return UInt32(lower.dropFirst(2), radix: 16)
    }

    /// 只接受清单所在目录下的相对路径(不能是绝对路径、带协议的地址、百分号编码或包含 ..),防止清单把下载指向别处。
    static func resolve(_ path: String, relativeTo manifestURL: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("%"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              let url = URL(string: path, relativeTo: manifestURL)?.absoluteURL,
              url.scheme == manifestURL.scheme, url.host == manifestURL.host else { return nil }
        return url
    }
}

nonisolated enum FirmwareError: LocalizedError, Equatable {
    case toolMissing
    case network(String)
    case badManifest(String)
    case incompatible(String)
    case checksumMismatch(String)
    case unsafeOffset(String)
    case noPort
    case backupFailed(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing: String(localized: "app 缺少烧录工具 esptool，请重新安装 InputBetter，或在官网用浏览器刷入", bundle: .l10n)
        case .network(let m): String(localized: "无法从官网获取固件：\(m)", bundle: .l10n)
        case .badManifest(let m): String(localized: "官网固件清单有误（\(m)），已停止", bundle: .l10n)
        case .incompatible(let v): String(localized: "官网的固件 \(v) 需要更新版本的 InputBetter，请先更新 app", bundle: .l10n)
        case .checksumMismatch(let f): String(localized: "下载的 \(f) 校验不通过，请重试", bundle: .l10n)
        case .unsafeOffset(let f): String(localized: "\(f) 的写入范围会覆盖受保护分区，已停止", bundle: .l10n)
        case .noPort: String(localized: "没有找到 USB 连接的 Passport", bundle: .l10n)
        case .backupFailed(let m): String(localized: "备份失败：\(m)", bundle: .l10n)
        case .toolFailed(let m): m
        }
    }
}
