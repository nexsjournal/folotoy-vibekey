import SwiftUI
// 见 SystemTranslator:Translation 框架类型未标注 Sendable,按框架约定使用。
@preconcurrency import Translation

/// 系统翻译(离线)某个目标语言对应语言对的语言包状态与下载
/// (由 `SystemTranslationRows` 组合使用:引导的"翻译与 AI"一步、设置 › 翻译服务 › 系统翻译「配置…」;字幕和听写的目标语言各一行)。
/// - 「下载」:通过 `.translationTask` 调 `prepareTranslation()`,由系统弹出下载确认框(Apple 推荐的应用内下载方式);
/// - 「在系统设置中管理」:打开 系统设置 › 通用 › 语言与地区,底部「翻译语言…」可以下载 / 删除语言包。
/// 下载完成、或从系统设置回到 app 时自动刷新状态(TranslationService 监听 app 激活)。
struct SystemTranslationRow: View {
    let translation: TranslationService
    /// 检查哪个目标语言的语言包(字幕或听写的目标语言)。
    let target: TargetLanguage
    var title: LocalizedStringKey = "系统翻译（离线）"
    @State private var request: TranslationSession.Configuration?
    @State private var error: String?

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(status == .installed ? AnyShapeStyle(DS.success) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(verbatim: error).font(.system(size: 11)).foregroundStyle(DS.danger)
                }
            }
            Spacer()
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
            case .needsDownload:
                Button("下载") { startDownload() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(request != nil)
                manageButton
            case .installed, .unsupported:
                manageButton
            }
        }
        .task { await translation.refreshSystemStatus() }
        .translationTask(request) { session in
            do {
                try await session.prepareTranslation()
                error = nil
            } catch {
                // 用户在系统弹窗里取消也会走到这里,不算错误。
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            request = nil
            await translation.systemDownloadFinished()
        }
    }

    private var status: TranslationService.SystemStatus { translation.systemStatus(for: target) }

    private var pairName: String {
        let pair = translation.downloadPair(for: target)
        return "\(SystemTranslator.name(pair.source)) → \(SystemTranslator.name(pair.target))"
    }

    private var statusText: String {
        switch status {
        case .checking: String(localized: "正在检查语言包…", bundle: .l10n)
        case .installed: String(localized: "已下载（\(pairName)），翻译立即出结果，免费且不联网", bundle: .l10n)
        case .needsDownload: String(localized: "未下载（\(pairName)）。翻译需要这两种语言的语言包，系统会一起下载；下载后字幕翻译几乎实时，免费且不联网", bundle: .l10n)
        case .unsupported: String(localized: "系统翻译不支持 \(pairName)，请换用在线翻译服务或 AI 大模型", bundle: .l10n)
        }
    }

    private var manageButton: some View {
        Button("在系统设置中管理") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("系统设置 › 通用 › 语言与地区 › 翻译语言")
    }

    private func startDownload() {
        error = nil
        let pair = translation.downloadPair(for: target)
        request = TranslationSession.Configuration(source: pair.source, target: pair.target)
    }
}
