import Foundation

/// 设置里那个 LLM 服务提供的模型列表(`GET {base}/models`),供 设置 › AI 服务 的模型选择框、
/// 字幕条「翻译方式」、听写润色和字幕记录「总结」选模型共用(同一份列表只拉取一次)。
/// - 只拉取一次并缓存(内存 + UserDefaults,按接口地址区分,不存 Key),打开菜单时就有内容;
/// - 接口地址或 Key 改了自动重新拉取(停顿 1 秒,避免边输入边请求);菜单里也可以手动刷新;
/// - 只要接口地址非空就拉取,不要求已选模型——第一次配置时正是要从列表里选模型。
/// 线程:主 actor;同一时间只有最新一次拉取的结果生效(旧请求被取消,结果按 generation 丢弃)。
@MainActor @Observable
final class LLMModelCatalog {
    private(set) var models: [String] = []
    private(set) var loading = false
    /// 最近一次拉取失败的原因(成功或清空地址后为 nil)。
    private(set) var error: String?
    /// `models` 来自哪个接口地址(nil = 还没有列表)。界面据此判断"这个地址确实没有返回模型"。
    private(set) var loadedBase: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 每次 refresh 递增;请求回来时不是最新一次就丢弃结果,避免旧请求覆盖新状态(包括 loading)。
    @ObservationIgnored private var generation = 0
    private static let cacheKey = "llm.models.cache"

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        if let cache = defaults.dictionary(forKey: Self.cacheKey), cache["base"] as? String == settings.llmBaseURL {
            models = cache["ids"] as? [String] ?? []
            loadedBase = settings.llmBaseURL
        }
        observeChanges({ [weak self] in _ = (self?.settings.llmBaseURL, self?.settings.llmAPIKey) }) { [weak self] in
            self?.refresh(delay: .seconds(1))
        }
    }

    /// 适合聊天 / 翻译的模型(去掉嵌入、语音、图像、审核类模型)。
    var chatModels: [String] { Self.chatCandidates(models) }

    /// 重新拉取。接口地址为空时清空列表和错误,不发请求。
    func refresh(delay: Duration = .zero) {
        task?.cancel()
        generation += 1
        let current = generation
        let base = settings.llmBaseURL, key = settings.llmAPIKey
        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            models = []
            loadedBase = nil
            error = nil
            loading = false
            return
        }
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, current == generation else { return }
            loading = true
            do {
                let ids = try await OpenAICompatibleAPI.listModels(baseURL: base, apiKey: key)
                guard current == generation else { return }
                models = ids
                loadedBase = base
                error = nil
                defaults.set(["base": base, "ids": ids], forKey: Self.cacheKey)
            } catch {
                guard current == generation else { return }
                // 换了接口地址却拉取失败:旧地址的列表不属于新地址,清掉;同一地址失败(如 Key 失效)保留缓存的列表。
                if loadedBase != base {
                    models = []
                    loadedBase = nil
                }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    /// 还没有列表时拉取一次(启动时调用)。
    func loadIfNeeded() {
        if models.isEmpty { refresh() }
    }

    nonisolated static func chatCandidates(_ ids: [String]) -> [String] {
        let excluded = ["embed", "whisper", "tts", "dall-e", "image", "moderation", "transcri", "audio", "rerank", "realtime", "speech", "vision-preview"]
        return ids.filter { id in
            let lower = id.lowercased()
            return !excluded.contains { lower.contains($0) }
        }
    }
}
