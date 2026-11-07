import SwiftUI

/// 快捷键:听写、翻译听写、开关字幕、状态条回到底部中央,每个一个录制框。
struct ShortcutsPane: View {
    let app: AppState

    var body: some View {
        SettingsSection(title: "快捷键", footer: "点录制框后按下新的组合键即可修改。翻译听写的翻译方式和目标语言在 设置 › 听写 里设置。") {
            ShortcutsCard(settings: app.settings, includeMore: true)
        }
    }
}
