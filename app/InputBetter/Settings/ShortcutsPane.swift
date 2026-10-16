import SwiftUI

/// 快捷键:听写、翻译听写、开关字幕,每个一个录制框。
struct ShortcutsPane: View {
    let app: AppState

    var body: some View {
        SettingsSection(title: "快捷键", footer: "点录制框后按下新的组合键即可修改。翻译听写需要先在「AI 润色与翻译」里配置 AI。") {
            ShortcutsCard(settings: app.settings, includeSubtitles: true)
        }
    }
}
