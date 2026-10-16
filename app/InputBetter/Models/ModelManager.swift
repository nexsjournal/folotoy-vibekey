import Foundation
import Speech
import WhisperKit

nonisolated enum ModelState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)
    case unsupported(String)
}

/// 下载、校验、删除本地模型。只有写入 `.installed` 标记后才算安装完成,
/// 下载到一半的文件不会被当成可用模型。
@MainActor @Observable
final class ModelManager {
    private(set) var states: [String: ModelState] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let settings: AppSettings
    /// 云端模型是否"可用"取决于配置,不缓存,每次从这里读取。
    private let cloud: CloudASRStore

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("InputBetter/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var senseVoiceDir: URL { root.appendingPathComponent("sensevoice-small", isDirectory: true) }
    static var whisperBase: URL { root.appendingPathComponent("whisper", isDirectory: true) }

    private static let senseVoiceRepo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    private static let senseVoiceFiles = ["model.int8.onnx", "tokens.txt"]

    init(settings: AppSettings, cloud: CloudASRStore) {
        self.settings = settings
        self.cloud = cloud
        refresh()
    }

    func state(_ id: String) -> ModelState {
        if let provider = ModelCatalog.model(id)?.cloudProvider {
            return cloud.isConfigured(provider) ? .installed : .notInstalled
        }
        return states[id] ?? .notInstalled
    }
    func isInstalled(_ id: String) -> Bool { state(id) == .installed }

    /// 模型不可用时给用户看的原因:本地模型"未下载",云端模型"未配置"。
    func unavailableMessage(_ id: String) -> String {
        guard let model = ModelCatalog.model(id) else {
            return String(localized: "请先在设置里选择识别模型", bundle: .l10n)
        }
        return model.cloudProvider == nil
            ? String(localized: "\(model.name) 尚未下载，请在 设置 › 识别模型 里下载", bundle: .l10n)
            : String(localized: "\(model.name) 尚未配置，请在 设置 › 识别模型 里填写 API Key", bundle: .l10n)
    }

    func refresh() {
        for model in ModelCatalog.all {
            if case .downloading = states[model.id] { continue }
            switch model.engine {
            case .appleSpeech:
                Task { await refreshAppleSpeech() }
            case .cloud:
                continue
            default:
                states[model.id] = Self.markerExists(model.id) ? .installed : .notInstalled
            }
        }
    }

    /// Whisper 模型目录(下载时记录在标记文件里)。
    static func whisperFolder(_ id: String) -> URL? {
        guard let path = try? String(contentsOf: marker(id), encoding: .utf8) else { return nil }
        let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 下载

    func download(_ id: String) {
        // 云端模型没有下载步骤(界面上是"配置")。
        guard let model = ModelCatalog.model(id), model.cloudProvider == nil, tasks[id] == nil else { return }
        states[id] = .downloading(0)
        tasks[id] = Task {
            do {
                switch model.engine {
                case .whisper(let variant): try await downloadWhisper(id: id, variant: variant)
                case .senseVoice: try await downloadSenseVoice(id: id)
                case .appleSpeech: try await installAppleSpeech(id: id)
                case .cloud: return
                }
                states[id] = .installed
                Log.models.info("model installed: \(id, privacy: .public)")
            } catch is CancellationError {
                states[id] = .notInstalled
            } catch {
                if Task.isCancelled {
                    states[id] = .notInstalled
                } else {
                    Log.models.error("download \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    states[id] = .failed(error.localizedDescription)
                }
            }
            tasks[id] = nil
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        states[id] = .notInstalled
    }

    func delete(_ id: String) {
        cancel(id)
        guard let model = ModelCatalog.model(id) else { return }
        let fm = FileManager.default
        switch model.engine {
        case .whisper:
            if let folder = Self.whisperFolder(id) { try? fm.removeItem(at: folder) }
        case .senseVoice:
            try? fm.removeItem(at: Self.senseVoiceDir)
        case .appleSpeech, .cloud:
            return
        }
        try? fm.removeItem(at: Self.marker(id))
        states[id] = .notInstalled
    }

    /// 下载源顺序:优先用户选择的源,失败后自动换另一个(镜像有时只是重定向回官方源)。
    private var hosts: [String] {
        let origin = "https://huggingface.co", mirror = "https://hf-mirror.com"
        return settings.useMirror ? [mirror, origin] : [origin, mirror]
    }

    /// 依次尝试每个下载源,全部失败时抛出第一个错误。
    private func withHostFallback(_ body: (String) async throws -> Void) async throws {
        var firstError: Error?
        for host in hosts {
            do {
                try await body(host)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                Log.models.error("download from \(host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                firstError = firstError ?? error
            }
        }
        throw firstError ?? CancellationError()
    }

    private func downloadWhisper(id: String, variant: String) async throws {
        try await withHostFallback { host in
            let folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: Self.whisperBase,
                endpoint: host,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = self.states[id] { self.states[id] = .downloading(fraction) }
                    }
                })
            try Task.checkCancellation()
            try folder.path.write(to: Self.marker(id), atomically: true, encoding: .utf8)
        }
    }

    private func downloadSenseVoice(id: String) async throws {
        let dir = Self.senseVoiceDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await withHostFallback { host in
            // tokens.txt 很小,按模型文件的进度显示即可。
            for (index, file) in Self.senseVoiceFiles.enumerated() {
                let url = URL(string: "\(host)/\(Self.senseVoiceRepo)/resolve/main/\(file)")!
                let isModel = index == 0
                let downloader = FileDownloader(destination: dir.appendingPathComponent(file)) { written, total in
                    guard isModel, total > 0 else { return }
                    let fraction = Double(written) / Double(total)
                    Task { @MainActor in
                        if case .downloading = self.states[id] { self.states[id] = .downloading(fraction * 0.99) }
                    }
                }
                _ = try await downloader.download(url)
                try Task.checkCancellation()
            }
            try dir.path.write(to: Self.marker(id), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Apple Speech

    private func refreshAppleSpeech() async {
        let id = "apple-speech"
        guard SpeechTranscriber.isAvailable else {
            states[id] = .unsupported(String(localized: "此 Mac 不支持", bundle: .l10n))
            return
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: settings.language.appleLocale) else {
            states[id] = .unsupported(String(localized: "不支持\(settings.language.title)", bundle: .l10n))
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: states[id] = .installed
        case .downloading: states[id] = .downloading(0.5)
        case .supported: states[id] = .notInstalled
        default: states[id] = .unsupported(String(localized: "不支持\(settings.language.title)", bundle: .l10n))
        }
    }

    private func installAppleSpeech(id: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: settings.language.appleLocale) else {
            throw NSError(domain: "InputBetter", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Apple Speech 不支持\(settings.language.title)", bundle: .l10n)])
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let progress = request.progress
        let poll = Task {
            while !Task.isCancelled {
                states[id] = .downloading(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { poll.cancel() }
        try await request.downloadAndInstall()
    }

    /// 语言变化后 Apple Speech 需要对应区域的资源。
    func languageChanged() {
        Task { await refreshAppleSpeech() }
    }

    // MARK: - 标记文件

    private static func marker(_ id: String) -> URL { root.appendingPathComponent("\(id).installed") }
    private static func markerExists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: marker(id).path) }
}
