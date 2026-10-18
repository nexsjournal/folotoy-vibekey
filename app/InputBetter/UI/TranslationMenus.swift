import SwiftUI

/// 目标语言菜单项(字幕条「译」菜单、字幕记录「译文」菜单共用)。
/// 当前语言打勾;点哪一项由调用方决定含义(字幕条:点新语言 = 开启翻译,再点当前语言 = 关闭)。
struct TargetLanguageMenuItems: View {
    /// 当前打勾的语言(nil = 都不勾,如字幕条没开翻译时)。
    let selected: TargetLanguage?
    let onSelect: (TargetLanguage) -> Void

    var body: some View {
        ForEach(TargetLanguage.allCases) { language in
            Toggle(isOn: Binding(get: { selected == language }, set: { _ in onSelect(language) })) {
                if language == .auto {
                    Text("\(language.title)（\(TargetLanguage.autoSummary)）")
                } else {
                    Text(verbatim: language.title)
                }
            }
        }
    }
}

/// 翻译方式菜单项(字幕条方式菜单、字幕记录方式菜单、设置 › 翻译 的实时字幕 / 听写「翻译方式」共用):
/// 系统翻译 → 已配置的在线服务 → AI 大模型(直接列出可选模型)→ 添加翻译服务(未配置的,点了直接打开配置表单)→ 实时字幕设置(在设置里时不显示)。
/// 不可用的方式置灰并写明原因,避免选了才发现用不了。
struct TranslationMethodMenuItems: View {
    let current: TranslationMethod
    /// 按哪个目标语言判断系统翻译能不能用(听写传听写的目标语言;nil = 字幕的目标语言)。
    var target: TargetLanguage? = nil
    let translation: TranslationService
    let catalog: LLMModelCatalog
    let settings: AppSettings
    let onSelect: (TranslationMethod) -> Void
    /// 配置某个在线服务(弹出配置表单)。
    let onConfigure: (TranslationProvider) -> Void
    /// 系统翻译的配置(下载语言包)。
    let onConfigureSystem: () -> Void
    /// 打开 设置 › AI 服务(配置 LLM 接口)。
    let onConfigureLLM: () -> Void
    /// 打开 设置 › 实时字幕(字幕的方式 / 默认语言 / 行数都在那里;已经在设置里时为 nil,不显示这一项)。
    let onSettings: (() -> Void)?

    private var providers: MachineTranslationStore { translation.providers }

    private var currentModel: String {
        if case .llm(let model) = current { return model }
        return ""
    }

    var body: some View {
        Section("本机") {
            if translation.systemStatus(for: target ?? settings.subtitleTarget) == .needsDownload {
                // 语言包没下载:不是死胡同,直接给出下载入口。
                Button("系统翻译（离线）· 下载语言包…", action: onConfigureSystem)
            } else {
                option(.system, title: String(localized: "系统翻译（离线）", bundle: .l10n))
            }
        }
        if !providers.configured.isEmpty {
            Section("在线翻译") {
                ForEach(providers.configured) { provider in
                    option(.provider(provider), title: provider.displayName)
                }
            }
        }
        Section("AI 大模型") {
            if settings.llmConfigured {
                LLMModelMenuItems(selected: current.isLLM ? currentModel : nil, catalog: catalog, settings: settings) {
                    onSelect(.llm(model: $0))
                }
            } else {
                Button("配置 AI 服务…", action: onConfigureLLM)
            }
        }
        let unconfigured = TranslationProvider.allCases.filter { !providers.isConfigured($0) }
        if !unconfigured.isEmpty {
            Divider()
            Menu("添加在线翻译服务") {
                ForEach(unconfigured) { provider in
                    Button { onConfigure(provider) } label: {
                        Text(verbatim: "\(provider.displayName)…")
                    }
                }
            }
        }
        if let onSettings {
            Divider()
            Button("实时字幕设置…", action: onSettings)
        }
    }

    /// 一种方式:当前方式打勾;不可用时置灰并附上原因。
    private func option(_ method: TranslationMethod, title: String) -> some View {
        let reason = translation.unavailableReason(method, target: target)
        return Toggle(isOn: Binding(get: { current.sameKind(as: method) }, set: { _ in onSelect(method) })) {
            if let reason {
                Text(verbatim: "\(title)（\(reason)）")
            } else {
                Text(verbatim: title)
            }
        }
        .disabled(reason != nil)
    }

}

extension TranslationMethod {
    /// 界面上的简称:系统翻译 / DeepL / AI · 模型名。
    @MainActor
    func shortLabel(model: String?) -> String {
        switch self {
        case .system: String(localized: "系统翻译", bundle: .l10n)
        case .provider(let provider): provider.shortName
        case .llm: "AI · \(model ?? "")"
        }
    }
}
