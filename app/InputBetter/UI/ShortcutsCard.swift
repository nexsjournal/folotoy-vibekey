import KeyboardShortcuts
import SwiftUI

/// 快捷键卡片:听写 / 翻译听写(/ 开关字幕)。引导页和设置页共用,保持简单——每个功能一个录制框。
struct ShortcutsCard: View {
    let settings: AppSettings
    /// 设置页额外显示"开关实时字幕"。
    var includeSubtitles = false

    var body: some View {
        Card {
            VStack(spacing: DS.Space.m) {
                SettingRow(title: "听写", detail: "按住说话，松开输入；轻按一下则免提，再按一下结束") {
                    KeyboardShortcuts.Recorder(for: .dictate)
                }
                Divider()
                SettingRow(title: "翻译听写", detail: "说完自动翻译成\(settings.translateTarget.title)再输入（需要配置 AI）") {
                    KeyboardShortcuts.Recorder(for: .translateDictate)
                }
                if includeSubtitles {
                    Divider()
                    SettingRow(title: "开关实时字幕", detail: "使用上次选择的应用") {
                        KeyboardShortcuts.Recorder(for: .toggleSubtitles)
                    }
                }
            }
        }
    }
}
