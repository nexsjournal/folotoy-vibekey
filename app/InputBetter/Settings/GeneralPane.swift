import ServiceManagement
import SwiftUI

/// 通用:权限状态、麦克风、识别语言、状态条与提示音、开机启动。
struct GeneralPane: View {
    let app: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "权限") {
                VStack(spacing: DS.Space.s) {
                    PermissionRow(symbol: "mic.fill",
                                  title: "麦克风", detail: "听写时录音",
                                  granted: app.permissions.microphone == .authorized) { app.permissions.requestMicrophone() }
                    PermissionRow(symbol: "keyboard.fill",
                                  title: "辅助功能", detail: "快捷键与输入文字",
                                  granted: app.permissions.accessibility, buttonTitle: "去开启") { app.permissions.requestAccessibility() }
                }
            }

            SettingsSection(title: "输入", footer: "Passport 的 OK 键始终可以开始听写；这里只决定由哪个麦克风收音。") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        SettingRow(title: "麦克风") {
                            Picker("", selection: $settings.micID) {
                                Text("系统默认（\(app.inputDevices.defaultDeviceName)）").tag("")
                                ForEach(app.inputDevices.devices) { Text($0.name).tag($0.uid) }
                                Divider()
                                Text(app.deviceLink.connection == .disconnected ? LocalizedStringKey("Passport 麦克风（未连接）") : LocalizedStringKey("Passport 麦克风"))
                                    .tag(AppSettings.passportMicID)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Divider()
                        SettingRow(title: "识别语言", detail: "中英混说选「自动检测」或「中文」") {
                            Picker("", selection: $settings.language) {
                                ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            }

            SettingsSection(title: "外观与提示") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        SettingRow(title: "界面语言") {
                            LanguagePicker(language: app.language)
                        }
                        Divider()
                        SettingRow(title: "显示底部状态条", detail: "鼠标悬停可开始听写或打开字幕") {
                            Toggle("", isOn: $settings.showPill).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        SettingRow(title: "提示音", detail: "开始和结束录音时播放") {
                            Toggle("", isOn: $settings.soundEffects).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        SettingRow(title: "登录时启动") {
                            Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                                .onChange(of: launchAtLogin) { _, on in
                                    do {
                                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                    } catch {
                                        launchAtLogin = SMAppService.mainApp.status == .enabled
                                    }
                                }
                        }
                    }
                }
            }

            SettingsSection(title: "关于") {
                Card {
                    HStack {
                        Text(verbatim: "InputBetter \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(.system(size: 13))
                        Spacer()
                        Button("重新运行引导") { app.windows.showOnboarding() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }
}
