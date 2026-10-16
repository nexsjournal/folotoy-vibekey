import SwiftUI

/// 实时字幕:选择应用开始 / 停止,字号、翻译、锁定。
struct SubtitlesPane: View {
    let app: AppState
    @State private var apps: [AudioApp] = []

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "选择应用", footer: "系统音频按应用采集：选择 Chrome 就会转录 Chrome 里所有标签页的声音。") {
                Card {
                    VStack(spacing: 0) {
                        if apps.isEmpty { Hint("没有正在运行的应用") }
                        ForEach(apps) { audioApp in
                            appRow(audioApp)
                            if audioApp.id != apps.last?.id { Divider().padding(.leading, 36) }
                        }
                    }
                }
            }
            SettingsSection(title: "显示") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        SettingRow(title: "字号") {
                            HStack {
                                Slider(value: $settings.subtitleFontSize, in: 14...44, step: 2).frame(width: 180)
                                Text(verbatim: "\(Int(settings.subtitleFontSize))").monospacedDigit().frame(width: 24)
                            }
                        }
                        Divider()
                        SettingRow(title: "显示译文", detail: app.translation.isAvailable ? "目标语言：\(settings.subtitleTarget.title)（在 AI 设置里修改）" : "需要下载系统翻译语言或配置 AI") {
                            Toggle("", isOn: $settings.subtitleTranslate).labelsHidden().toggleStyle(.switch)
                                .disabled(!app.translation.isAvailable)
                        }
                        Divider()
                        SettingRow(title: "锁定字幕条", detail: "锁定后鼠标点击会穿透，不挡视频控件") {
                            Toggle("", isOn: $settings.subtitleLocked).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
            }
            SettingsSection(title: "字幕记录", footer: "InputBetter 不保存字幕历史：记录只在内存中，下次开始字幕或退出后清除。需要留存时请保存成文件。") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        SettingRow(title: "结束时询问是否保存", detail: "保存为文本文件，位置由你选择") {
                            Toggle("", isOn: $settings.askToSaveCaptions).labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        SettingRow(title: "本次字幕记录") {
                            Button("查看") { app.windows.showTranscript() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            }
        }
        .onAppear { apps = AudioProcesses.runningApps() }
    }

    private func appRow(_ audioApp: AudioApp) -> some View {
        let running = app.subtitles.isRunning && app.subtitles.appBundleID == audioApp.bundleID
        return HStack(spacing: DS.Space.m) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: audioApp.bundleID)?.path ?? ""))
                .resizable().frame(width: 24, height: 24)
            Text(audioApp.name).font(.system(size: 13))
            if audioApp.isPlaying { Tag(text: "正在播放", color: DS.warning) }
            Spacer()
            Button(running ? LocalizedStringKey("结束字幕") : LocalizedStringKey("开始字幕")) {
                running ? app.stopCaptions() : app.startCaptions(audioApp)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.vertical, 6)
    }
}
