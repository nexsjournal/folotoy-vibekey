import SwiftUI

/// 系统翻译(离线)语言包的状态行:实时字幕和听写各自的目标语言各一行;两个场景目标语言相同时合并成一行。
/// 设置 › 翻译服务 › 系统翻译「配置…」表单和引导的"翻译与 AI"一步共用,保证两处列出的语言包一致。
/// 只负责按目标语言决定显示几行,每行的状态和下载由 `SystemTranslationRow` 完成;外层卡片由调用方提供。
struct SystemTranslationRows: View {
    let translation: TranslationService
    let settings: AppSettings

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if settings.subtitleTarget == settings.translateTarget {
                SystemTranslationRow(translation: translation, target: settings.subtitleTarget, title: "实时字幕和听写")
            } else {
                SystemTranslationRow(translation: translation, target: settings.subtitleTarget, title: "实时字幕")
                Divider()
                SystemTranslationRow(translation: translation, target: settings.translateTarget, title: "听写翻译")
            }
        }
    }
}
