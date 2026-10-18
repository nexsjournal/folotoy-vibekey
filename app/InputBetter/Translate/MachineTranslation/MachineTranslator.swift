import Foundation

/// 在线机器翻译接口:一次翻译若干句,返回与输入等长、同序的译文。
/// 实现不保存状态,可以在任意线程调用;源语言交给服务端自动识别(本机对短句的识别不够可靠)。
nonisolated protocol MachineTranslator: Sendable {
    var provider: TranslationProvider { get }
    /// - Parameters:
    ///   - texts: 非空、不含换行的句子;
    ///   - target: 具体的目标语言(不会是 .auto)。
    func translate(_ texts: [String], to target: TargetLanguage) async throws -> [String]
}

/// 在线翻译的错误,按处理方式归类:可重试(限流、服务端暂时故障、网络)/ 应停止整批(密钥、额度、时间)。
nonisolated enum MachineTranslationError: LocalizedError, Equatable {
    case notConfigured
    /// 密钥无效、没有权限、服务没开通。
    case auth(String)
    /// 额度用完、欠费。
    case quotaExceeded(String)
    /// 请求太频繁。`retryAfter`:服务端在 `Retry-After` 头里建议的等待秒数(没有给出时为 nil),
    /// 重试逻辑(TranslationService.withRetry)优先按它等待。
    case rateLimited(String, retryAfter: TimeInterval? = nil)
    /// 本机时间不准,签名过期(火山 / 腾讯要求时间误差在几分钟内)。
    case clockSkew
    /// 不支持这个语言。
    case unsupportedLanguage
    /// 服务端暂时故障或网络问题(可以重试)。
    case transient(String)
    /// 其他服务端错误。
    case server(String)
    /// 返回的内容无法解析,或句数对不上。
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "还没有配置密钥", bundle: .l10n)
        case .auth(let detail): String(localized: "密钥无效或没有权限（\(detail)）", bundle: .l10n)
        case .quotaExceeded(let detail): String(localized: "额度已用完或账户欠费（\(detail)）", bundle: .l10n)
        case .rateLimited: String(localized: "请求太频繁，请稍后再试", bundle: .l10n)
        case .clockSkew: String(localized: "签名已过期，请检查系统时间是否准确", bundle: .l10n)
        case .unsupportedLanguage: String(localized: "不支持这个目标语言", bundle: .l10n)
        case .transient(let detail): String(localized: "服务暂时不可用（\(detail)）", bundle: .l10n)
        case .server(let detail): detail
        case .badResponse: String(localized: "服务返回的内容无法解析", bundle: .l10n)
        }
    }

    /// 稍后重试可能成功。
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .transient: true
        default: false
        }
    }

    /// 重试也不会成功,整批任务应该停下并提示用户。
    var abortsBatch: Bool {
        switch self {
        case .notConfigured, .auth, .quotaExceeded, .clockSkew, .unsupportedLanguage: true
        default: false
        }
    }
}
