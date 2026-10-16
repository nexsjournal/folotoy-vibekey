import SwiftUI

/// Vibe Coding:用 Passport / 快捷键和 Claude Code、Codex 对话;Agent 完成或请求确认时提醒你。
struct VibePane: View {
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "工作流") {
                Card {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        step("1", "按住 Passport 的 OK 键（或快捷键）对 Claude Code / Codex 说出需求")
                        step("2", "按 ▲ 回车发送；Agent 跑偏时按 ▼ Esc 打断")
                        step("3", "Agent 完成或请求确认时，Passport 响铃并亮屏，状态条也会提醒")
                    }
                }
            }

            SettingsSection(title: "Agent 通知", footer: "一键配置会写入各自的 hook 配置，只追加 InputBetter 自己的条目；原文件会先备份为 .inputbetter.bak。") {
                Card {
                    VStack(spacing: DS.Space.m) {
                        ForEach(AgentHookInstaller.Agent.allCases) { agent in
                            AgentHookRow(agent: agent)
                            if agent != AgentHookInstaller.Agent.allCases.last { Divider() }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("测试通知") { app.agent.post(.done, source: "Claude Code") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, DS.Space.xs)
            }
        }
    }

    private func step(_ number: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Text(verbatim: number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(DS.accent))
            Text(text).font(.system(size: 12.5))
        }
    }
}

/// 一个 Agent 的配置行:名称 + 状态 + 一键配置。
private struct AgentHookRow: View {
    let agent: AgentHookInstaller.Agent
    @State private var installed = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: agent.name).font(.system(size: 13, weight: .medium))
                Text(verbatim: detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(error == nil ? Color.secondary : DS.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if installed {
                Label("已配置", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.success)
            } else {
                Button("一键配置") { install() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .onAppear { installed = AgentHookInstaller.isInstalled(agent) }
    }

    private var detail: String {
        if let error { return error }
        let path = agent.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if installed, let followUp = agent.followUp { return "\(path) · \(followUp)" }
        return path
    }

    private func install() {
        do {
            try AgentHookInstaller.install(agent)
            installed = true
            error = nil
        } catch {
            self.error = String(localized: "配置失败：\(error.localizedDescription)", bundle: .l10n)
        }
    }
}
