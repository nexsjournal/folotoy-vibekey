import SwiftUI

/// 系统翻译(离线)的「配置…」:实时字幕和听写各自目标语言需要的语言包,状态、下载和到系统设置里管理。
/// 显示几行由 `SystemTranslationRows` 决定(两个场景目标语言相同时只显示一行)。
struct SystemTranslationSheet: View {
    let translation: TranslationService
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("系统翻译（离线）").font(.system(size: 16, weight: .semibold))
                Text(verbatim: TranslationMethod.system.detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Card { SystemTranslationRows(translation: translation, settings: settings) }
            Hint("语言包由 macOS 管理，下载一次后所有 app 都能离线使用；也可以在 系统设置 › 通用 › 语言与地区 › 翻译语言 中下载或删除。")
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 560)
    }
}
