import Foundation
// Translation 框架的类型没有标注 Sendable(以 Swift 5 模式编译)。会话和可用性查询只在主线程上创建和发起,
// 框架内部自行处理并发;用 @preconcurrency 让编译器按框架的约定处理,而不是报"跨隔离域传递"。
@preconcurrency import Translation

/// macOS 自带的离线翻译(Translation 框架)。
/// - 只用已下载的语言包(`TranslationSession(installedSource:target:)`,macOS 26 起可以不经界面直接调用);
///   未下载时抛出 `notInstalled`,下载要通过界面里的 `.translationTask` 由系统弹窗确认(见 SystemTranslationRow)。
/// - 每个语言对复用一个会话;macOS 26.4 起优先低延迟策略。
/// - 语言包状态有缓存,下载完成或 app 重新激活时 `invalidate` 后重新查询。
@MainActor
final class SystemTranslator {
    enum TranslatorError: LocalizedError {
        case notInstalled(String, String)
        case unsupported(String, String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let from, let to): String(localized: "系统翻译语言未下载（\(from) → \(to)）", bundle: .l10n)
            case .unsupported(let from, let to): String(localized: "系统翻译不支持 \(from) → \(to)", bundle: .l10n)
            }
        }
    }

    private var sessions: [String: TranslationSession] = [:]
    private var statuses: [String: LanguageAvailability.Status] = [:]
    private let availability = LanguageAvailability()

    /// 语言包状态(有缓存)。
    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        let key = Self.key(source, target)
        if let cached = statuses[key] { return cached }
        let status = await availability.status(from: source, to: target)
        statuses[key] = status
        return status
    }

    /// 翻译一段文字。源语言和目标语言相同时原样返回。
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        if LanguageDetector.same(source, target) { return text }
        switch await status(from: source, to: target) {
        case .installed: break
        case .supported: throw TranslatorError.notInstalled(Self.name(source), Self.name(target))
        case .unsupported: throw TranslatorError.unsupported(Self.name(source), Self.name(target))
        @unknown default: throw TranslatorError.unsupported(Self.name(source), Self.name(target))
        }
        let session = session(source, target)
        let response = try await session.translate(text)
        return response.targetText
    }

    /// 清空缓存的状态和会话(语言包下载 / 删除之后调用)。
    func invalidate() {
        statuses = [:]
        sessions.values.forEach { $0.cancel() }
        sessions = [:]
    }

    private func session(_ source: Locale.Language, _ target: Locale.Language) -> TranslationSession {
        let key = Self.key(source, target)
        if let existing = sessions[key] { return existing }
        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
        sessions[key] = session
        return session
    }

    private static func key(_ source: Locale.Language, _ target: Locale.Language) -> String {
        "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
    }

    /// 给用户看的语言名(按 app 当前的界面语言)。
    static func name(_ language: Locale.Language) -> String {
        Locale(identifier: L10n.code(for: AppLanguage.saved)).localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }
}
