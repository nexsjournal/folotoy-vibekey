import Foundation

/// 支持的云端语音识别服务。选型依据见 docs/architecture.md「云端识别」:
/// - 火山引擎豆包流式识别 2.0:普通话准确率最好,国内可用;
/// - 阿里云百炼 Fun-ASR 实时识别:方言覆盖最广,国内(北京)和国际(新加坡)都可用;
/// - ElevenLabs Scribe v2 Realtime:国际可用,中文 / 粤语高准确率档;
/// - OpenAI 兼容转写接口:按句上传,兼容 OpenAI、Groq 等任何 `/audio/transcriptions` 服务。
/// 都采用"用户自带密钥"模式,密钥只存在本机(CredentialStore)。
nonisolated enum CloudProvider: String, CaseIterable, Identifiable, Sendable {
    case volcengine, bailian, elevenlabs, openAICompatible

    var id: String { rawValue }

    /// 在模型目录中的 ID。
    var modelID: String { "cloud-\(rawValue)" }

    var displayName: String {
        switch self {
        case .volcengine: String(localized: "火山引擎 · 豆包流式识别", bundle: .l10n)
        case .bailian: String(localized: "阿里云百炼 · Fun-ASR 实时识别", bundle: .l10n)
        case .elevenlabs: "ElevenLabs · Scribe v2 Realtime"
        case .openAICompatible: String(localized: "OpenAI 兼容转写接口", bundle: .l10n)
        }
    }

    var detail: String {
        switch self {
        case .volcengine: String(localized: "普通话准确率很高，支持中英混说和多种方言；适合中国大陆。", bundle: .l10n)
        case .bailian: String(localized: "方言覆盖最广（粤语、吴语、闽南语等），中英文都好；有中国大陆和国际两个区域。", bundle: .l10n)
        case .elevenlabs: String(localized: "国际服务，中文、粤语、英文准确率高，延迟低。", bundle: .l10n)
        case .openAICompatible: String(localized: "按句上传识别，兼容 OpenAI、Groq 等接口；字幕延迟较高。", bundle: .l10n)
        }
    }

    /// 发给 Passport 屏幕的短名(ASCII)。
    var shortName: String {
        switch self {
        case .volcengine: "Doubao ASR"
        case .bailian: "Fun-ASR"
        case .elevenlabs: "Scribe"
        case .openAICompatible: "Cloud ASR"
        }
    }

    /// 是否原生流式(否则走本地 VAD 分段 + 逐句上传)。
    var isStreaming: Bool { self != .openAICompatible }

    /// 获取 API Key 的控制台地址。
    var consoleURL: URL {
        switch self {
        case .volcengine: URL(string: "https://console.volcengine.com/speech/app")!
        case .bailian: URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")!
        case .elevenlabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .openAICompatible: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// 可选区域(仅百炼需要)。
    var regions: [CloudRegion] {
        self == .bailian ? [.mainland, .international] : []
    }

    /// 默认模型(可在配置里修改)。
    var defaultModel: String {
        switch self {
        case .volcengine: "volc.seedasr.sauc.duration"
        case .bailian: "fun-asr-realtime"
        case .elevenlabs: "scribe_v2_realtime"
        case .openAICompatible: "gpt-4o-mini-transcribe"
        }
    }

    /// 是否需要填写接口地址(OpenAI 兼容服务)。
    var needsBaseURL: Bool { self == .openAICompatible }
}

nonisolated enum CloudRegion: String, CaseIterable, Identifiable, Sendable {
    case mainland, international

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainland: String(localized: "中国大陆（北京）", bundle: .l10n)
        case .international: String(localized: "国际（新加坡）", bundle: .l10n)
        }
    }
}

/// 一个云服务的配置(密钥在 CredentialStore,其余在 UserDefaults)。
nonisolated struct CloudConfig: Equatable, Sendable {
    var apiKey: String
    var model: String
    var region: CloudRegion
    var baseURL: String

    /// 必填项是否齐全(决定该模型是否"可用")。
    func isComplete(for provider: CloudProvider) -> Bool {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty, !model.isEmpty else { return false }
        if provider.needsBaseURL { return URL(string: baseURL)?.scheme?.hasPrefix("http") == true }
        return true
    }
}
