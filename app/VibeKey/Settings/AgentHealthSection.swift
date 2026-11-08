import AppKit
import ApplicationServices
import SwiftUI

/// Agent 导航健康状态：不是所有 Electron / WebView 应用都会暴露相同的 AX 树。
/// 这里让用户按应用逐个检测，失败时能区分“未安装 / 未运行 / AX 不可读”，
/// 而不是在设备上按了半天才发现没有会话列表。
struct AgentHealthSection: View {
    @State private var states: [String: Health] = [:]
    @State private var checking: String?

    private struct Agent: Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    private enum Health: Equatable {
        case idle
        case checking
        case ready(projects: Int, recent: Int)
        case failed(String)
    }

    private let agents = [
        Agent(bundleID: "com.openai.codex", name: "Codex"),
        Agent(bundleID: "ai.deepseek.dsh.desktop.next", name: "DeepSeek Honeycomb"),
        Agent(bundleID: "com.tencent.workbuddy.mac", name: "WorkBuddy"),
        Agent(bundleID: "dev.zcode.app", name: "ZCode"),
        Agent(bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
        Agent(bundleID: "com.alibaba.qwen.desktop", name: "千问办公"),
        Agent(bundleID: "com.bytedance.doubao.desktop", name: "豆包工作"),
    ]

    var body: some View {
        SettingsSection(title: "Agent 导航", footer: "只读侧栏标题、窗口标题和控件角色，不读取聊天正文。检测会把目标 App 前置并读取一次侧栏；失败时仍可在设备上当普通应用切换。") {
            Card {
                VStack(spacing: DS.Space.m) {
                    HStack {
                        Image(systemName: AXIsProcessTrusted() ? "checkmark.shield.fill" : "exclamationmark.shield")
                            .foregroundStyle(AXIsProcessTrusted() ? DS.success : DS.danger)
                        Text(AXIsProcessTrusted() ? "辅助功能权限已开启" : "需要辅助功能权限才能读取项目和会话")
                            .font(.system(size: 12))
                        Spacer()
                        if !AXIsProcessTrusted() {
                            Button("打开系统设置") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    Divider()
                    ForEach(agents) { agent in
                        row(agent)
                        if agent.id != agents.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func row(_ agent: Agent) -> some View {
        let installed = isInstalled(agent.bundleID)
        let running = isRunning(agent.bundleID)
        return HStack(spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.system(size: 12.5, weight: .medium))
                Text(statusText(agent.bundleID, installed: installed, running: running))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !installed {
                Text("未安装").font(.caption).foregroundStyle(.secondary)
            } else if !running {
                Text("未运行").font(.caption).foregroundStyle(.secondary)
            } else if checking == agent.bundleID {
                ProgressView().controlSize(.small)
            } else {
                Button("检测") { check(agent) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(checking != nil)
            }
        }
    }

    private func statusText(_ bundleID: String, installed: Bool, running: Bool) -> String {
        guard installed else { return String(localized: "未安装", bundle: .l10n) }
        guard running else { return String(localized: "未运行；打开它之后可以检测", bundle: .l10n) }
        switch states[bundleID] ?? .idle {
        case .idle: return String(localized: "已运行，等待检测", bundle: .l10n)
        case .checking: return String(localized: "正在读取侧栏…", bundle: .l10n)
        case .ready(let projects, let recent):
            return String(localized: "可读取：\(projects) 个项目、\(recent) 条最近会话", bundle: .l10n)
        case .failed(let message): return message
        }
    }

    private func check(_ agent: Agent) {
        guard AXIsProcessTrusted(),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: agent.bundleID).first,
              let app = AgentSessionApp(running: running) else {
            states[agent.bundleID] = .failed(String(localized: "无法读取：请检查辅助功能权限和应用是否在前台", bundle: .l10n))
            return
        }
        checking = agent.bundleID
        states[agent.bundleID] = .checking
        Task {
            let catalog = await AgentSessionCatalogLoader.load(for: app)
            if let catalog {
                states[agent.bundleID] = .ready(projects: catalog.projects.count, recent: catalog.recent.count)
            } else {
                states[agent.bundleID] = .failed(String(localized: "未检测到聊天输入框 + 侧栏；可当普通应用切换", bundle: .l10n))
            }
            checking = nil
        }
    }

    private func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
