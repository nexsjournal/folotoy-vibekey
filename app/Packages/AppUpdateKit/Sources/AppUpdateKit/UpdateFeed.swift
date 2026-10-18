import Foundation

/// 一个可下载的新版本(来自更新数据源)。
public struct UpdateRelease: Sendable, Equatable {
    public let version: AppVersion
    /// 更新说明,按语言代码(`zh`、`en`……)存放;某种语言没写时为空字符串或缺省。
    public let notes: [String: String]
    /// 「下载更新」打开的地址(安装包或官网下载页)。
    public let downloadURL: URL
    public let publishedAt: Date?

    public init(version: AppVersion, notes: [String: String] = [:], downloadURL: URL, publishedAt: Date? = nil) {
        self.version = version
        self.notes = notes
        self.downloadURL = downloadURL
        self.publishedAt = publishedAt
    }

    /// 按界面语言取更新说明:先找完全匹配(`zh-Hans`),再找语言部分(`zh`),都没有时用任意一种非空的说明。
    public func notes(for languageCode: String) -> String {
        let base = languageCode.split(separator: "-").first.map(String.init) ?? languageCode
        for key in [languageCode, base] {
            if let text = notes[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return notes.keys.sorted().compactMap { notes[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// 数据源返回的发布信息:最新版本,以及「版本 ≤ 多少必须更新」。
public struct UpdateFeedResult: Sendable, Equatable {
    /// 没有为这个平台发布任何版本时为 nil。
    public let latest: UpdateRelease?
    /// 版本号小于等于它的客户端必须更新;nil 表示不强制。
    public let requiredAtOrBelow: AppVersion?

    public init(latest: UpdateRelease?, requiredAtOrBelow: AppVersion? = nil) {
        self.latest = latest
        self.requiredAtOrBelow = requiredAtOrBelow
    }
}

/// 更新数据源:从服务器(或任何地方)取最新的发布信息。由 app 注入,AppUpdateKit 不关心它连的是哪个后台。
/// 实现必须线程安全;取消调用方的 Task 时应尽快结束。
public protocol UpdateFeed: Sendable {
    func fetch() async throws -> UpdateFeedResult
}

/// 固定返回同一结果的数据源:测试和调试界面用。
public struct StaticUpdateFeed: UpdateFeed {
    public let result: UpdateFeedResult
    public init(_ result: UpdateFeedResult) { self.result = result }
    public func fetch() async throws -> UpdateFeedResult { result }
}
