import AppKit

/// DictationController 依赖的小接口。控制器只通过它们拿引擎、做后处理、输入文字,
/// 不直接依赖 ModelManager / EngineRegistry / TextProcessor / TranslationService 的内部实现,
/// 测试里可以换成假实现(见 DictationChainTests)。

/// 听写用的识别引擎来源。
@MainActor
protocol DictationEngineSource: AnyObject {
    /// 模型可用(已下载 / 已配置)时返回它的引擎,否则 nil。
    func dictationEngine(for modelID: String) -> ASREngine?
}

/// 听写后处理(润色 / 翻译)。
@MainActor
protocol DictationPostProcessing: AnyObject {
    /// 听写翻译现在不能用的原因(界面直接显示);nil 表示可用。
    var translationUnavailableReason: String? { get }
    /// 这种模式下会执行的处理步骤(胶囊显示「润色中」/「翻译中」);nil 表示直接输入原文。
    func step(for mode: DictationController.Mode) -> ProcessingStep?
    /// 执行处理。失败时退回原文并带上警告,不丢用户说的话;被取消时返回原文、不带警告(调用方自己检查取消)。
    func process(_ text: String, mode: DictationController.Mode) async -> PostProcessed
}

/// 把文字输入到焦点窗口。
@MainActor
protocol TextInserting: AnyObject {
    func insert(_ text: String, target: NSRunningApplication?) async -> TextInserter.Outcome
}

extension TextInserter: TextInserting {}

/// 默认的引擎来源:ModelManager 判断模型是否可用,EngineRegistry 提供(并缓存)引擎。
@MainActor
final class InstalledDictationEngines: DictationEngineSource {
    private let models: ModelManager
    private let engines: EngineRegistry

    init(models: ModelManager, engines: EngineRegistry) {
        self.models = models
        self.engines = engines
    }

    func dictationEngine(for modelID: String) -> ASREngine? {
        guard models.isInstalled(modelID) else { return nil }
        return engines.engine(for: modelID)
    }
}
