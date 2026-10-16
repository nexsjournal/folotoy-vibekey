import Foundation

/// 按模型 ID 创建并缓存识别引擎。听写与字幕可以共用同一个已加载的引擎。
@MainActor @Observable
final class EngineRegistry {
    /// 正在加载的模型 ID(界面据此显示"加载模型中")。
    private(set) var loadingModelID: String?
    @ObservationIgnored private var engines: [String: ASREngine] = [:]
    @ObservationIgnored private let cloud: CloudASRStore

    init(cloud: CloudASRStore) {
        self.cloud = cloud
    }

    func engine(for modelID: String) -> ASREngine? {
        if let e = engines[modelID] { return e }
        guard let info = ModelCatalog.model(modelID) else { return nil }
        let engine: ASREngine = switch info.engine {
        case .whisper: WhisperEngine(modelID: modelID)
        case .senseVoice: SenseVoiceEngine()
        case .appleSpeech: AppleSpeechEngine()
        case .cloud(let provider): CloudASREngine(provider: provider, store: cloud)
        }
        engines[modelID] = engine
        return engine
    }

    /// 预加载模型,避免第一次听写时等待。失败只记录日志,真正使用时会再报错。
    func preload(_ modelID: String) {
        guard let engine = engine(for: modelID), !engine.isLoaded else { return }
        loadingModelID = modelID
        Task {
            do { try await engine.prepare() } catch {
                Log.asr.error("preload \(modelID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            if loadingModelID == modelID { loadingModelID = nil }
        }
    }

    /// 释放除 `keep` 以外的引擎,切换模型后回收内存。
    func unloadAll(except keep: Set<String>) {
        for (id, engine) in engines where !keep.contains(id) {
            engine.unload()
            engines[id] = nil
        }
    }
}
