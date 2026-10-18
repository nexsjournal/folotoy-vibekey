import Foundation

/// 通用的 JSON 更新数据源:GET 一个地址,解析下面的格式。可以是自建服务器的接口,也可以是放在网站上的静态 JSON 文件。
///
/// ```json
/// {
///   "latest": {                       // 没有发布任何版本时为 null
///     "version": "1.2.0",             // 1–4 段数字
///     "build": "42",                  // 可选,数字
///     "notes": {"zh": "…", "en": "…"},// 可选,按语言代码
///     "url": "https://…/App-1.2.0.dmg",// 「下载更新」打开的地址,必须是 HTTPS
///     "publishedAt": 1760000000000    // 可选,毫秒时间戳
///   },
///   "requiredAtOrBelow": "1.0.3"      // 可选,版本 ≤ 它的客户端必须更新;"" 或省略表示不强制
/// }
/// ```
/// 0os Console 的 `GET /v1/app/update` 返回的就是这个格式(多出的字段忽略)。
/// 是否需要更新由 AppUpdateKit 在本机计算(`UpdateVerdict`),不依赖服务器给出结论。
public struct JSONUpdateFeed: UpdateFeed {
    public let url: URL
    /// 额外的查询参数(如 `platform=macos`),追加在 `url` 已有的参数之后。
    public let queryItems: [URLQueryItem]
    /// 额外的请求头(如自建接口需要的应用标识)。
    public let headers: [String: String]
    public var session: URLSession = .shared

    public init(url: URL, queryItems: [URLQueryItem] = [], headers: [String: String] = [:]) {
        self.url = url
        self.queryItems = queryItems
        self.headers = headers
    }

    public enum FeedError: LocalizedError, Equatable {
        case http(Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .http(let status): "HTTP \(status)"
            case .invalidResponse: "Invalid update response"
            }
        }
    }

    public func fetch() async throws -> UpdateFeedResult {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw FeedError.invalidResponse }
        if !queryItems.isEmpty { components.queryItems = (components.queryItems ?? []) + queryItems }
        guard let target = components.url else { throw FeedError.invalidResponse }
        // 每次都向服务器确认(不用 HTTP 缓存),发布或撤销强制更新后立即生效。
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedError.invalidResponse }
        guard http.statusCode == 200 else { throw FeedError.http(http.statusCode) }
        return try Self.decode(data)
    }

    /// 解析返回内容。下载地址只接受 HTTPS;版本号格式不对视为无效响应(宁可不提示,也不乱提示)。
    public static func decode(_ data: Data) throws -> UpdateFeedResult {
        struct Body: Decodable {
            struct Latest: Decodable {
                let version: String
                let build: String?
                let notes: [String: String]?
                let url: String
                let publishedAt: Double?
            }
            let latest: Latest?
            let requiredAtOrBelow: String?
        }
        let body: Body
        do { body = try JSONDecoder().decode(Body.self, from: data) } catch { throw FeedError.invalidResponse }
        var floor: AppVersion?
        if let required = body.requiredAtOrBelow, !required.isEmpty {
            guard let parsed = AppVersion(required) else { throw FeedError.invalidResponse }
            floor = parsed
        }
        guard let latest = body.latest else { return UpdateFeedResult(latest: nil, requiredAtOrBelow: floor) }
        guard let version = AppVersion(latest.version, build: latest.build),
              let link = URL(string: latest.url), link.scheme == "https", link.host != nil else { throw FeedError.invalidResponse }
        return UpdateFeedResult(
            latest: UpdateRelease(version: version, notes: latest.notes ?? [:], downloadURL: link,
                                  publishedAt: latest.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) }),
            requiredAtOrBelow: floor)
    }
}
