import Foundation

/// 当前版本面对一次发布时应该怎么做。
public enum UpdateVerdict: Sendable, Equatable {
    /// 已是最新(或比发布的还新,例如开发版)。
    case upToDate
    /// 有新版本,可以稍后或跳过。
    case available(UpdateRelease)
    /// 有新版本,而且当前版本不再受支持,必须更新。
    case required(UpdateRelease)

    /// 纯函数:判断 `current` 面对 `result` 时的结论(与后台的 `updateStatus` 规则一致)。
    /// 只有确实存在比当前更新的版本时才会强制;后台配置失误(强制版本 ≥ 最新版本)也不会把最新版锁死。
    public static func evaluate(current: AppVersion, result: UpdateFeedResult) -> UpdateVerdict {
        guard let latest = result.latest, current < latest.version else { return .upToDate }
        if let floor = result.requiredAtOrBelow, current.compareVersion(floor) != .orderedDescending {
            return .required(latest)
        }
        return .available(latest)
    }
}
