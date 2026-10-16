import Foundation

/// 云端识别引擎:按服务类型创建会话。每次创建会话时读取最新配置,修改配置后无需重启。
/// - 流式服务(火山 / 百炼 / ElevenLabs):StreamingCloudSession + 对应编解码器;
/// - OpenAI 兼容接口:SegmentedSession + OpenAITranscriptionDecoder(本地 VAD 分段)。
@MainActor
final class CloudASREngine: ASREngine {
    let provider: CloudProvider
    private let store: CloudASRStore

    init(provider: CloudProvider, store: CloudASRStore) {
        self.provider = provider
        self.store = store
    }

    var isLoaded: Bool { true }

    func prepare() async throws {
        guard store.isConfigured(provider) else { throw CloudASRError.notConfigured(provider.displayName) }
    }

    func makeSession(_ options: ASROptions) async throws -> ASRSession {
        try await prepare()
        return Self.session(provider: provider, config: store.config(provider), options: options)
    }

    func unload() {}

    /// 根据配置创建会话(也用于设置页的"测试连接")。
    static func session(provider: CloudProvider, config: CloudConfig, options: ASROptions) -> ASRSession {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .volcengine:
            return StreamingCloudSession(purpose: options.purpose) {
                VolcengineCodec(apiKey: key, resourceID: config.model, options: options)
            }
        case .bailian:
            return StreamingCloudSession(purpose: options.purpose) {
                BailianCodec(apiKey: key, model: config.model, region: config.region, options: options)
            }
        case .elevenlabs:
            return StreamingCloudSession(purpose: options.purpose) {
                ElevenLabsCodec(apiKey: key, model: config.model, options: options)
            }
        case .openAICompatible:
            return SegmentedSession(decoder: OpenAITranscriptionDecoder(baseURL: config.baseURL, apiKey: key, model: config.model),
                                    options: options)
        }
    }

    /// 测试连接:送 1.5 秒近乎静音的音频并结束,没有收到错误即视为可用。返回错误说明,nil 表示正常。
    static func test(provider: CloudProvider, config: CloudConfig) async -> String? {
        let options = ASROptions(purpose: .dictation, language: .auto, vocabulary: [])
        // 静音里加一点极小的噪声,避免部分服务把纯零数据判为"空音频"错误。
        let noise = (0..<24_000).map { _ in Float.random(in: -0.0005...0.0005) }
        // OpenAI 兼容接口按段请求:直接发一次转写请求验证地址、鉴权和模型名。
        if provider == .openAICompatible {
            do {
                _ = try await OpenAITranscriptionDecoder(baseURL: config.baseURL, apiKey: config.apiKey, model: config.model)
                    .decode(noise, options: options)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let testSession = Self.session(provider: provider, config: config, options: options)
        let collector = Task.detached { () -> String? in
            for await event in testSession.events {
                if case .failure(let message) = event { return message }
            }
            return nil
        }
        testSession.feed(noise)
        _ = await testSession.finish()
        return await collector.value
    }
}
