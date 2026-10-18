import AppKit
import AppUpdateKit
import SwiftUI

/// 设置 › 通用 顶部的「关于与更新」:图标、版本号、更新状态、检查更新、自动检查开关,以及官网 / GitHub / 支持链接。
/// 调用链:按钮 → UpdateChecker.checkNow → (结果)WindowManager.showUpdate;「查看」直接用最近一次检查的结论打开提示窗口。
/// 没有配置更新接口的版本(自行编译的开源版)也显示版本号,并说明为什么不能检查更新。
struct AboutSection: View {
    let app: AppState

    var body: some View {
        SettingsSection(title: "关于与更新",
                        footer: app.updates == nil ? "这个版本没有配置检查更新的接口（自行编译的开源版默认如此），新版本请到官网或 GitHub 查看。" : nil) {
            Card {
                VStack(spacing: DS.Space.m) {
                    HStack(spacing: DS.Space.m) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 52, height: 52)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "InputBetter").font(.system(size: 15, weight: .semibold))
                            Text("版本 \(Self.version)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let updates = app.updates {
                                UpdateStatusLine(updates: updates) { app.windows.showUpdate($0) }
                            }
                        }
                        Spacer()
                        if let updates = app.updates {
                            CheckButton(updates: updates)
                        }
                    }
                    if let updates = app.updates {
                        Divider()
                        AutomaticCheckRow(updates: updates)
                    }
                    Divider()
                    HStack(spacing: DS.Space.l) {
                        Link("官网", destination: Self.website)
                        Link(destination: Self.github) { Text(verbatim: "GitHub") }
                        Link("支持与反馈", destination: Self.support)
                        Spacer()
                        Button("重新运行引导") { app.windows.showOnboarding() }.buttonStyle(SecondaryButtonStyle())
                    }
                    .font(.system(size: 12.5))
                }
            }
        }
    }

    private static let website = URL(string: "https://input.0os.io")!
    private static let github = URL(string: "https://github.com/racall/InputBetter")!
    private static let support = URL(string: "https://input.0os.io/support/")!

    /// 版本号与构建号,如「0.1.4 (5)」。
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

/// 最近一次检查的结论:正在检查 / 已是最新 / 有新版本(可查看)/ 需要更新。还没检查过时不显示。
private struct UpdateStatusLine: View {
    let updates: UpdateChecker
    let show: (UpdateEvent) -> Void

    var body: some View {
        Group {
            if updates.phase == .checking {
                Label("正在检查更新…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            } else {
                switch updates.verdict {
                case .upToDate:
                    Label("已是最新版本", systemImage: "checkmark.circle.fill").foregroundStyle(DS.success)
                case .available(let release):
                    HStack(spacing: 6) {
                        Label("有新版本 \(release.version.description)", systemImage: "arrow.down.circle.fill").foregroundStyle(DS.accent)
                        Button("查看") { show(.update(release, required: false)) }.buttonStyle(.link)
                    }
                case .required(let release):
                    HStack(spacing: 6) {
                        Label("需要更新到 \(release.version.description)", systemImage: "exclamationmark.shield.fill").foregroundStyle(DS.warning)
                        Button("查看") { show(.update(release, required: true)) }.buttonStyle(.link)
                    }
                case nil:
                    EmptyView()
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
    }
}

/// 「检查更新」按钮:检查中显示转圈并禁用。
private struct CheckButton: View {
    let updates: UpdateChecker

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if updates.phase == .checking { ProgressView().controlSize(.small) }
            Button("检查更新") { updates.checkNow() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(updates.phase == .checking)
        }
    }
}

/// 「自动检查更新」开关与上次检查时间。
private struct AutomaticCheckRow: View {
    @Bindable var updates: UpdateChecker
    @Environment(\.locale) private var locale

    var body: some View {
        SettingRow(title: "自动检查更新", detailText: lastChecked) {
            Toggle("", isOn: $updates.automaticChecks).labelsHidden().toggleStyle(.switch)
        }
    }

    private var lastChecked: String {
        guard let date = updates.lastChecked else { return String(localized: "每天自动检查一次是否有新版本", bundle: .l10n) }
        let time = date.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(locale))
        return String(localized: "上次检查：\(time)", bundle: .l10n)
    }
}
