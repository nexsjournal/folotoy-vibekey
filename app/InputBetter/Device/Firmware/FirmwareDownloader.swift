import CryptoKit
import Foundation

/// 从官网获取 Passport 固件清单,并把镜像下载到本机缓存,逐个校验大小与 SHA-256。
///
/// - 清单每次都重新请求(不走 HTTP 缓存),这样官网发布新固件后立即可见;
/// - 镜像按「版本-构建标识」分目录缓存在 `~/Library/Caches/InputBetter/Firmware/`,已下载且校验通过的不再重复下载;
/// - 任何一个镜像校验失败都删除该文件并整体失败,绝不把不完整的固件交给 esptool。
/// 无状态、可在任意线程调用;取消调用方的 Task 会中止下载。
nonisolated struct FirmwareDownloader: Sendable {
    /// 下载好的一个镜像:写入地址与本机文件。
    struct LocalImage: Sendable, Equatable {
        let offset: UInt32
        let file: URL
    }

    static let officialManifestURL = URL(string: "https://input.0os.io/firmware/manifest.json")!
    static let defaultCacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("InputBetter/Firmware", isDirectory: true)

    let manifestURL: URL
    var cacheRoot: URL = Self.defaultCacheRoot
    var session: URLSession = .shared

    /// 请求最新的固件清单。
    func fetchManifest() async throws -> FirmwareManifest {
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await fetch(request)
        do {
            return try JSONDecoder().decode(FirmwareManifest.self, from: data)
        } catch {
            throw FirmwareError.badManifest(String(localized: "无法解析", bundle: .l10n))
        }
    }

    /// 下载清单里的全部镜像,`onProgress` 按字节数报告 0...1。返回顺序与清单一致。
    func download(_ manifest: FirmwareManifest, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [LocalImage] {
        let parts = try manifest.parts(relativeTo: manifestURL)
        let dir = cacheRoot.appendingPathComponent("\(Self.safeName(manifest.version))-\(Self.safeName(manifest.build))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = Double(parts.reduce(0) { $0 + $1.size })
        var done = 0.0
        var result: [LocalImage] = []
        onProgress(0)
        for part in parts {
            try Task.checkCancellation()
            let file = dir.appendingPathComponent(part.fileName)
            if !Self.matches(file, part) {
                let request = URLRequest(url: part.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                let data = try await fetch(request)
                guard data.count == part.size, Self.sha256(data) == part.sha256 else {
                    throw FirmwareError.checksumMismatch(part.fileName)
                }
                try data.write(to: file, options: .atomic)
            }
            result.append(LocalImage(offset: part.offset, file: file))
            done += Double(part.size)
            onProgress(total > 0 ? done / total : 1)
        }
        return result
    }

    /// 发请求并检查 HTTP 状态;网络错误统一转成 `FirmwareError.network`,取消原样抛出。
    private func fetch(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw FirmwareError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FirmwareError.network("HTTP \(http.statusCode)")
        }
        return data
    }

    /// 本机缓存的文件大小与校验值都对得上。
    static func matches(_ file: URL, _ part: FirmwareManifest.Part) -> Bool {
        guard let data = try? Data(contentsOf: file), data.count == part.size else { return false }
        return sha256(data) == part.sha256
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 版本号和构建标识用作目录名前,只保留安全字符。
    static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+"))
        let cleaned = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "unknown" : cleaned
    }
}
