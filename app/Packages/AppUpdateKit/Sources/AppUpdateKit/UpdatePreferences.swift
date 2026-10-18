import Foundation

/// 检查更新的本机偏好:是否自动检查、上次检查时间、跳过的版本。存在 UserDefaults(键带 `AppUpdateKit.` 前缀)。
/// 只在主线程读写(由 `UpdateChecker` 持有)。
@MainActor
public struct UpdatePreferences {
    private let defaults: UserDefaults
    private enum Key {
        static let automatic = "AppUpdateKit.automaticChecks"
        static let lastCheck = "AppUpdateKit.lastCheck"
        static let skipped = "AppUpdateKit.skippedVersion"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 是否自动检查更新(默认开启)。关闭后不再自动联网检查,用户仍可手动检查。
    public var automaticChecks: Bool {
        get { defaults.object(forKey: Key.automatic) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.automatic) }
    }

    public var lastCheck: Date? {
        get { defaults.object(forKey: Key.lastCheck) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.lastCheck) }
    }

    /// 用户选择「跳过此版本」的版本号;自动检查不再提示它,手动检查和强制更新不受影响。
    public var skippedVersion: String? {
        get { defaults.string(forKey: Key.skipped) }
        nonmutating set { defaults.set(newValue, forKey: Key.skipped) }
    }
}
