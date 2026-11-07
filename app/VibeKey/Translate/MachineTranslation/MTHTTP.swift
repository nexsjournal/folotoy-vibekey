import Foundation

/// 在线翻译的 HTTP 公共部分(各家只负责构造请求和解析响应):超时、发送、把网络错误归为可重试、
/// 解析 `Retry-After`、按状态码归类错误,以及 JSON 读取的小工具。各家的鉴权信息都放在请求头或请求体里。
nonisolated enum MTHTTP {
    /// 一次请求的结果。`retryAfter` 来自响应头 `Retry-After`(限流时服务端建议的等待秒数)。
    typealias Response = (data: Data, status: Int, retryAfter: TimeInterval?)

    /// 单次请求的超时:基础 10 秒(字幕要跟上语音,短请求慢了不如重试),
    /// 每多 500 个字符多给 1 秒(大批量 / 整篇重译时服务端处理更久),最多 30 秒。
    static func timeout(forCharacters count: Int) -> TimeInterval {
        min(30, 10 + TimeInterval(max(0, count)) / 500)
    }

    /// 按这批句子的总字符数算超时(各家 makeRequest 共用)。
    static func timeout(for texts: [String]) -> TimeInterval {
        timeout(forCharacters: texts.reduce(0) { $0 + $1.count })
    }

    /// 发送请求,返回响应体、状态码和 `Retry-After`。网络错误(超时、断网)转成 `.transient`,任务取消抛 CancellationError。
    static func send(_ request: URLRequest, session: URLSession) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return (data, http?.statusCode ?? 0, retryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw MachineTranslationError.transient(error.localizedDescription)
        }
    }

    /// 解析 `Retry-After`(RFC 9110 §10.2.3):非负整数秒,或 HTTP 日期(换算成距 `now` 的秒数,已过去则为 0)。
    /// HTTP 日期按规范要求同时接受 IMF-fixdate 和两种旧格式(RFC 850、asctime)。无法解析返回 nil。
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return seconds >= 0 ? TimeInterval(seconds) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    static func json(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    /// JSON 请求体(键排序:同样的内容得到同样的字节,签名可复现、便于测试)。
    static func body(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 没有更具体信息时的错误归类(按 HTTP 状态码)。408 请求超时、425 Too Early 都是暂时性的,可以重试。
    static func classify(status: Int, message: String, retryAfter: TimeInterval? = nil) -> MachineTranslationError {
        let detail = message.isEmpty ? "HTTP \(status)" : message
        switch status {
        case 401, 403: return .auth(detail)
        case 429: return .rateLimited(detail, retryAfter: retryAfter)
        case 408, 425, 500...599: return .transient(detail)
        default: return .server("HTTP \(status) \(message)".trimmingCharacters(in: .whitespaces))
        }
    }

    /// 错误信息只取开头一段(避免把很长的 HTML 错误页显示给用户)。
    static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(160), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
