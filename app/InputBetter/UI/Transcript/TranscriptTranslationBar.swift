import SwiftUI

/// 字幕记录窗口「字幕」页顶部的翻译工具条(和「总结」页的控制条同一风格):
///   [译文：简体中文 ⌄] [DeepL ⌄]                                   [⋯]
/// - 和字幕条的「译」一致:在语言菜单里选一个语言就把还没译成这个语言的句子翻译过去(没有单独的「翻译 N 句」按钮);
///   语言菜单里也可以隐藏 / 显示译文;方式菜单只选方式(默认跟随字幕条),换方式后要重译用 ⋯ 里的「全部重新翻译」;
/// - ⋯ 里是其余操作:翻译未翻译的句子(实时翻译漏掉的)、全部重新翻译、AI 润色译文;进行中显示进度和「取消」;
/// - 出错时下面多一行原因和「检查配置…」(直接打开当前方式的配置)。
struct TranscriptTranslationBar: View {
    let translator: TranscriptTranslator
    let translation: TranslationService
    let catalog: LLMModelCatalog
    let settings: AppSettings
    let onConfigure: (TranslationProvider) -> Void
    let onConfigureSystem: () -> Void
    let onConfigureLLM: () -> Void
    let onSettings: () -> Void

    var body: some View {
        @Bindable var translator = translator
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.m) {
                languageMenu(show: $translator.showTranslations)
                methodMenu
                Spacer(minLength: DS.Space.s)
                actions
            }
            if let error = translator.error, translator.job == nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.warning)
                    Text(verbatim: error).foregroundStyle(.secondary).lineLimit(2)
                    // 直接打开出错的那种方式的配置(密钥、语言包、AI 服务),而不是笼统的设置页。
                    Button("检查配置…", action: configureCurrentMethod).buttonStyle(.borderless)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 8)
        .onAppear { translator.resetIfNewSession() }
    }

    private func configureCurrentMethod() {
        if translator.errorKind == .polish { return onConfigureLLM() }
        switch translator.method {
        case .system: onConfigureSystem()
        case .provider(let provider): onConfigure(provider)
        case .llm: onConfigureLLM()
        }
    }

    // MARK: - 左侧:语言、方式

    private func languageMenu(show: Binding<Bool>) -> some View {
        Menu {
            Section("翻译成") {
                // 还没有译文时不勾语言(和字幕条一样:勾着会让人以为已经翻译过)。
                TargetLanguageMenuItems(selected: translator.hasTranslations ? translator.target : nil) { language in
                    translator.targetOverride = language
                    translator.showTranslations = true
                    translator.translateMissing()
                }
            }
            if translator.hasTranslations {
                Divider()
                Toggle("显示译文", isOn: show)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "translate").font(.system(size: 11))
                Text(languageLabel)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(translator.job != nil || translator.transcriptIsEmpty)
        .help("选一个语言，把字幕翻译成这个语言（只用于这个窗口）")
    }

    /// 还没有译文时是「翻译」(点开选语言就开始);有译文时显示当前语言或「已隐藏」。
    private var languageLabel: String {
        guard translator.hasTranslations else { return String(localized: "翻译", bundle: .l10n) }
        return translator.showTranslations
            ? String(localized: "译文：\(translator.target.title)", bundle: .l10n)
            : String(localized: "译文：已隐藏", bundle: .l10n)
    }

    private var methodMenu: some View {
        let method = translator.method
        return Menu {
            TranslationMethodMenuItems(current: method, target: translator.target, translation: translation, catalog: catalog, settings: settings,
                                       onSelect: { translator.methodOverride = $0 },
                                       onConfigure: onConfigure, onConfigureSystem: onConfigureSystem,
                                       onConfigureLLM: onConfigureLLM, onSettings: onSettings)
        } label: {
            HStack(spacing: 4) {
                if translator.unavailableReason != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.warning)
                }
                Text(verbatim: method.shortLabel(model: translation.modelName(method)))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 180, alignment: .leading)
        .disabled(translator.job != nil)
        .help(translator.unavailableReason ?? String(localized: "翻译方式", bundle: .l10n))
    }

    // MARK: - 右侧:操作

    @ViewBuilder
    private var actions: some View {
        if let job = translator.job {
            ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 80)
            Text(job.kind == .polish
                 ? String(localized: "AI 润色 \(job.done)/\(job.total)", bundle: .l10n)
                 : String(localized: "翻译 \(job.done)/\(job.total)", bundle: .l10n))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
            Button("取消") { translator.cancel() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
        } else {
            let pending = translator.pendingEntries.count
            let polishable = translator.polishableEntries.count
            Menu {
                Button(String(localized: "翻译未翻译的句子（\(pending) 句）", bundle: .l10n)) { translator.translateMissing() }
                    .disabled(translator.unavailableReason != nil || pending == 0)
                Button("全部重新翻译") { translator.retranslateAll() }
                    .disabled(translator.unavailableReason != nil || translator.transcriptIsEmpty)
                Button(translator.canPolish ? LocalizedStringKey("AI 润色译文") : LocalizedStringKey("AI 润色译文（需要配置 AI 服务）")) { translator.polish() }
                    .disabled(!translator.canPolish || polishable == 0)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多翻译操作")
        }
    }
}
