import SwiftUI
// 见 SystemTranslator:Translation 框架类型未标注 Sendable,按框架约定使用。
@preconcurrency import Translation

/// 系统翻译(离线)语言包的状态与下载(引导的"AI 与翻译"一步、设置 › AI 润色与翻译 共用)。
/// - 「下载」:通过 `.translationTask` 调 `prepareTranslation()`,由系统弹出下载确认框(Apple 推荐的应用内下载方式);
/// - 「在系统设置中管理」:打开 系统设置 › 通用 › 语言与地区,底部「翻译语言…」可以下载 / 删除语言包。
/// 下载完成、或从系统设置回到 app 时自动刷新状态(TranslationService 监听 app 激活)。
struct SystemTranslationRow: View {
    let translation: TranslationService
    @State private var request: TranslationSession.Configuration?
    @State private var error: String?

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text("系统翻译（离线）").font(.system(size: 13))
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(translation.systemStatus == .installed ? AnyShapeStyle(DS.success) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(verbatim: error).font(.system(size: 11)).foregroundStyle(DS.danger)
                }
            }
            Spacer()
            switch translation.systemStatus {
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

    private var pairName: String {
        let pair = translation.downloadPair
        return "\(SystemTranslator.name(pair.source)) → \(SystemTranslator.name(pair.target))"
    }

    private var statusText: String {
        switch translation.systemStatus {
        case .checking: String(localized: "正在检查语言包…", bundle: .l10n)
        case .installed: String(localized: "已下载（\(pairName)），翻译立即出结果，免费且不联网", bundle: .l10n)
        case .needsDownload: String(localized: "未下载（\(pairName)）。翻译需要这两种语言的语言包，系统会一起下载；下载后字幕翻译几乎实时，不需要 AI", bundle: .l10n)
        case .unsupported: String(localized: "系统翻译不支持 \(pairName)，将只用 AI 翻译", bundle: .l10n)
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
        let pair = translation.downloadPair
        request = TranslationSession.Configuration(source: pair.source, target: pair.target)
    }
}
