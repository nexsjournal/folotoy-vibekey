import KeyboardShortcuts
import SwiftUI

/// 快捷键卡片:听写 / 翻译听写(/ 开关字幕、状态条回到底部中央)。引导页和设置页共用,保持简单——每个功能一个录制框。
struct ShortcutsCard: View {
    let settings: AppSettings
    /// 设置页额外显示"开关实时字幕""状态条回到底部中央"(引导页只放听写相关的两个)。
    var includeMore = false

    var body: some View {
        Card {
            VStack(spacing: DS.Space.m) {
                SettingRow(title: "听写", detail: "按住说话，松开输入；轻按一下则免提，再按一下结束") {
                    KeyboardShortcuts.Recorder(for: .dictate)
                }
                Divider()
                SettingRow(title: "翻译听写", detail: "说完自动翻译再输入，目标语言：\(settings.translateTarget.title)") {
                    KeyboardShortcuts.Recorder(for: .translateDictate)
                }
                if includeMore {
                    Divider()
                    SettingRow(title: "开关实时字幕", detail: "按下后选择要配字幕的应用；运行中再按一次结束") {
                        KeyboardShortcuts.Recorder(for: .toggleSubtitles)
                    }
                    Divider()
                    SettingRow(title: "状态条回到底部中央", detail: "状态条或字幕条拖丢了、换了显示器时，按一下放回鼠标所在屏幕的底部中央；默认未设置") {
                        KeyboardShortcuts.Recorder(for: .resetPillPosition)
                    }
                }
            }
        }
    }
}
