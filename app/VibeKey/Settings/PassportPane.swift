import SwiftUI

/// Passport:连接状态、按键映射、蓝牙与息屏。
struct PassportPane: View {
    let app: AppState

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "设备") {
                PassportSetupView(model: app.passportSetup)
            }

            PassportConnectionSection(link: app.deviceLink)

            PassportWiFiSection(link: app.deviceLink)

            WallpaperSection(link: app.deviceLink)

            AgentHealthSection()

            SettingsSection(title: "语音输入目标", footer: "长按设备下键选择应用；Agent 应用还可以继续选项目和会话。按住 OK 时会自动切换到所选应用和输入框，同时开始收音。") {
                Card { HStack { Text(settings.deviceTargetName); Spacer(); Image(systemName: "scope").foregroundStyle(.secondary) } }
            }

            SettingsSection(title: "按键", footer: "按住 OK 键说话，松开转写；上键发送当前 Codex 输入框，下键停止任务，长按上键切换模式；录音时长按下键取消。") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        keyRow("▲ 上键", $settings.deviceUpAction)
                        Divider()
                        keyRow("▼ 下键", $settings.deviceDownAction)
                        Divider()
                        keyRow("▼ 长按下键", $settings.deviceDownLongAction)
                    }
                }
            }

            SettingsSection(title: "屏幕") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        SettingRow(title: "自动息屏") {
                            Picker("", selection: $settings.deviceScreenOff) {
                                Text("30 秒").tag(30)
                                Text("1 分钟").tag(60)
                                Text("5 分钟").tag(300)
                                Text("永不").tag(0)
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
            }
        }
    }

    private func keyRow(_ title: LocalizedStringKey, _ binding: Binding<KeyAction>) -> some View {
        SettingRow(title: title) {
            Picker("", selection: binding) {
                ForEach(KeyAction.selectable) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }
}
