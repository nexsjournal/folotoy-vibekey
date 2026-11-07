import Foundation

nonisolated enum EngineKind: Sendable, Equatable {
    case whisper(variant: String)
    case senseVoice
    case appleSpeech
    /// 云端识别(用户自带 API Key,不需要下载)。
    case cloud(CloudProvider)
}

nonisolated struct ModelInfo: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let detail: String
    let size: String
    let engine: EngineKind
    /// 卡片上的标签,如"推荐"。
    let badge: String?
    /// 卡片图标(SF Symbol 名)。
    let symbol: String

    static func == (a: ModelInfo, b: ModelInfo) -> Bool { a.id == b.id }

    var engineName: String {
        switch engine {
        case .whisper: "WhisperKit"
        case .senseVoice: "sherpa-onnx"
        case .appleSpeech: "Apple"
        case .cloud: String(localized: "云端", bundle: .l10n)
        }
    }

    /// 发给 Passport 屏幕显示的短名(ASCII)。
    var shortName: String {
        if case .cloud(let provider) = engine { return provider.shortName }
        return switch id {
        case "whisper-turbo-632": "Whisper Turbo"
        case "whisper-turbo": "Whisper Turbo HQ"
        case "whisper-small": "Whisper Small"
        case "sensevoice-small": "SenseVoice"
        default: "Apple Speech"
        }
    }
}

/// 内置模型目录,按推荐顺序排列。
nonisolated enum ModelCatalog {
    static let defaultModelID = "whisper-turbo-632"

    /// 每次访问时生成,名称和说明跟随当前界面语言。
    static var all: [ModelInfo] { [
        ModelInfo(
            id: "whisper-turbo-632",
            name: String(localized: "Whisper Large v3 Turbo（压缩版）", bundle: .l10n),
            detail: String(localized: "多语言高准确率，压缩构建更省空间。", bundle: .l10n),
            size: String(localized: "约 650 MB", bundle: .l10n),
            engine: .whisper(variant: "openai_whisper-large-v3-v20240930_turbo_632MB"),
            badge: String(localized: "推荐", bundle: .l10n),
            symbol: "waveform"),
        ModelInfo(
            id: "sensevoice-small",
            name: "SenseVoice Small",
            detail: String(localized: "中文、粤语、英、日、韩，速度极快，自带标点。", bundle: .l10n),
            size: String(localized: "约 240 MB", bundle: .l10n),
            engine: .senseVoice,
            badge: String(localized: "中文极速", bundle: .l10n),
            symbol: "bolt.fill"),
        ModelInfo(
            id: "apple-speech",
            name: "Apple Speech",
            detail: String(localized: "系统内置引擎，实时流式识别，占用最小；按所选识别语言工作。", bundle: .l10n),
            size: String(localized: "系统管理", bundle: .l10n),
            engine: .appleSpeech,
            badge: String(localized: "免下载", bundle: .l10n),
            symbol: "apple.logo"),
        ModelInfo(
            id: "whisper-turbo",
            name: "Whisper Large v3 Turbo",
            detail: String(localized: "完整版，语言覆盖最广。", bundle: .l10n),
            size: String(localized: "约 1.6 GB", bundle: .l10n),
            engine: .whisper(variant: "openai_whisper-large-v3-v20240930_turbo"),
            badge: nil,
            symbol: "waveform.circle.fill"),
        ModelInfo(
            id: "whisper-small",
            name: "Whisper Small",
            detail: String(localized: "更轻量的多语言模型，下载更小。", bundle: .l10n),
            size: String(localized: "约 490 MB", bundle: .l10n),
            engine: .whisper(variant: "openai_whisper-small"),
            badge: nil,
            symbol: "waveform.path"),
    ] + cloudModels }

    /// 云端识别模型(排在本地模型之后)。
    static var cloudModels: [ModelInfo] {
        CloudProvider.allCases.map { provider in
            ModelInfo(
                id: provider.modelID,
                name: provider.displayName,
                detail: provider.detail,
                size: String(localized: "需联网 · 按量计费", bundle: .l10n),
                engine: .cloud(provider),
                badge: nil,
                symbol: "cloud")
        }
    }

    static func model(_ id: String) -> ModelInfo? { all.first { $0.id == id } }
}

extension ModelInfo {
    /// 云端模型:不需要下载,配置好 API Key 即可使用。
    nonisolated var cloudProvider: CloudProvider? {
        if case .cloud(let provider) = engine { provider } else { nil }
    }
}
