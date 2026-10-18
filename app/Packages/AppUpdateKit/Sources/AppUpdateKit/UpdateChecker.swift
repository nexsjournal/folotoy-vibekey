import Foundation
import Observation

/// 需要 app 显示给用户的检查结果。
public enum UpdateEvent: Sendable, Equatable {
    /// 有新版本(`required` 为 true 时必须更新,界面不应提供「稍后」「跳过」)。
    case update(UpdateRelease, required: Bool)
    /// 已是最新:只在用户手动检查时发出。
    case upToDate
    /// 检查失败:只在用户手动检查时发出(自动检查失败静默,下次再试)。
    case failed(String)
}

/// 检查更新的调度与状态(业内通行的做法,参考 Sparkle):
///
/// - `start()` 后,启动片刻先检查一次,之后每 `interval`(默认 24 小时)检查一次;
///   用「上次检查时间」判断是否到期,所以电脑睡眠、app 重启都不会打乱节奏,也不会频繁请求;
/// - 用户关闭「自动检查」后不再自动联网,`checkNow()` 仍可手动检查;
/// - 自动检查发现的可选更新,用户「跳过此版本」后不再提示该版本;强制更新每次都提示;
/// - 自动检查失败静默(网络不通很常见),手动检查才报告失败。
///
/// 结果通过 `present` 交给 app 显示;`verdict` 是最近一次成功检查的结论(强制更新窗口可据此在后台撤销强制后自动关闭)。
/// 只在主线程使用。
@MainActor @Observable
public final class UpdateChecker {
    public enum Phase: Sendable, Equatable { case idle, checking }

    public let currentVersion: AppVersion
    public private(set) var phase: Phase = .idle
    public private(set) var verdict: UpdateVerdict?
    public private(set) var lastChecked: Date?
    /// 把检查结果显示给用户(由 app 设置)。
    @ObservationIgnored public var present: ((UpdateEvent) -> Void)?

    /// 是否自动检查(写入本机偏好)。
    public var automaticChecks: Bool {
        didSet {
            preferences.automaticChecks = automaticChecks
            if automaticChecks { scheduleSoonIfDue() }
        }
    }

    @ObservationIgnored private let feed: any UpdateFeed
    @ObservationIgnored private let preferences: UpdatePreferences
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var userWaiting = false

    /// - Parameters:
    ///   - interval: 两次自动检查的间隔;
    ///   - now: 当前时间(测试注入)。
    public init(feed: any UpdateFeed, currentVersion: AppVersion, preferences: UpdatePreferences = UpdatePreferences(),
                interval: TimeInterval = 24 * 60 * 60, now: @escaping () -> Date = Date.init) {
        self.feed = feed
        self.currentVersion = currentVersion
        self.preferences = preferences
        self.interval = interval
        self.now = now
        automaticChecks = preferences.automaticChecks
        lastChecked = preferences.lastCheck
    }

    /// 开始自动检查。`launchDelay` 后检查一次(不和启动抢资源),之后每小时看一次是否到期。可重复调用。
    public func start(launchDelay: Duration = .seconds(5)) {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: launchDelay)
            // 每次启动都检查一次:强制更新要尽快生效,一次请求的代价很小。
            if let self, self.automaticChecks { await self.check(userInitiated: false) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                guard let self, !Task.isCancelled else { return }
                if self.automaticChecks, self.isDue { await self.check(userInitiated: false) }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 用户点「检查更新」:无论结果如何都会通过 `present` 报告(包括已是最新、失败,以及已跳过的版本)。
    public func checkNow() {
        Task { await check(userInitiated: true) }
    }

    /// 用户对可选更新选择「跳过此版本」。
    public func skip(_ release: UpdateRelease) {
        preferences.skippedVersion = release.version.description
    }

    /// 执行一次检查。正在检查时不重复请求;用户手动检查时等这次结果出来再报告。
    func check(userInitiated: Bool) async {
        if userInitiated { userWaiting = true }
        guard phase != .checking else { return }
        phase = .checking
        defer { phase = .idle }
        do {
            let result = try await feed.fetch()
            let checkedAt = now()
            preferences.lastCheck = checkedAt
            lastChecked = checkedAt
            let verdict = UpdateVerdict.evaluate(current: currentVersion, result: result)
            self.verdict = verdict
            let reportAll = userWaiting
            userWaiting = false
            switch verdict {
            case .upToDate:
                if reportAll { present?(.upToDate) }
            case .required(let release):
                present?(.update(release, required: true))
            case .available(let release):
                if reportAll || preferences.skippedVersion != release.version.description {
                    present?(.update(release, required: false))
                }
            }
        } catch is CancellationError {
            userWaiting = false
        } catch {
            if userWaiting { present?(.failed(error.localizedDescription)) }
            userWaiting = false
        }
    }

    private var isDue: Bool {
        guard let last = preferences.lastCheck else { return true }
        let elapsed = now().timeIntervalSince(last)
        // 时钟被往回调过(elapsed < 0)也视为到期,避免永远不检查。
        return elapsed >= interval || elapsed < 0
    }

    /// 重新打开自动检查时,如果已经到期就尽快检查一次。
    private func scheduleSoonIfDue() {
        guard loop != nil, isDue else { return }
        Task { await check(userInitiated: false) }
    }
}
