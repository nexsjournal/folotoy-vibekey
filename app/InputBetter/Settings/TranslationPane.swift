import SwiftUI

/// 设置 › 翻译服务:只负责"配置"——系统翻译语言包、6 家在线翻译服务的密钥、AI 服务。
/// 每行常驻「配置…」,并标出被哪个场景使用;选用哪个服务在 设置 › 听写 / 设置 › 实时字幕 的「翻译方式」里选
/// (和字幕条上的方式菜单是同一个菜单)。翻译在两种场景里工作,各自单独设置。
struct TranslationPane: View {
    let app: AppState
    @Bindable var navigation: SettingsNavigation

    private var settings: AppSettings { app.settings }
    private var translation: TranslationService { app.translation }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "翻译服务", footer: "配置好的服务会出现在[听写](inputbetter-settings://dictation)、[实时字幕](inputbetter-settings://subtitles)的「翻译方式」和字幕条的翻译方式菜单里。密钥只保存在本机；使用在线服务时，要翻译的文字会发送到该服务商。") {
                Card {
                    VStack(spacing: 0) {
                        serviceRow(.system)
                        ForEach(TranslationProvider.allCases) { provider in
                            Divider()
                            serviceRow(.provider(provider))
                        }
                        Divider()
                        serviceRow(.llm(model: ""))
                    }
                }
            }
        }
        .settingsLinks(navigation)
        .sheet(item: $navigation.configuringProvider) { provider in
            TranslationProviderSheet(provider: provider, store: app.translationProviders,
                                     initialUsage: usage(for: provider),
                                     onSaved: { usage in apply(usage, to: provider) },
                                     onRemoved: { providerRemoved(provider) })
        }
        .sheet(isPresented: $navigation.showingSystemTranslation) {
            SystemTranslationSheet(translation: translation, settings: settings)
        }
        .onChange(of: navigation.configuringProvider) { _, provider in
            if provider == nil { navigation.providerUse = nil }
        }
    }

    // MARK: - 翻译服务

    /// 一个服务:名称、状态、被哪个场景使用、说明;右侧常驻「配置…」(弹出表单 / 跳到别的设置页,按 macOS 惯例带省略号)。
    private func serviceRow(_ method: TranslationMethod) -> some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: serviceTitle(method)).font(.system(size: 13))
                    status(method)
                    if settings.subtitleTranslationMethod.sameKind(as: method) { Tag(text: "实时字幕在用", color: DS.accent) }
                    if settings.dictationTranslationMethod.sameKind(as: method) { Tag(text: "听写在用", color: DS.accent) }
                }
                Text(verbatim: serviceDetail(method)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                if case .provider(let provider) = method {
                    Text(verbatim: provider.freeTier).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: DS.Space.m)
            Button("配置…") { configureService(method) }
                .buttonStyle(SecondaryButtonStyle())
                .help(configureHelp(method))
        }
        .padding(.vertical, 8)
    }

    /// 服务名。AI 行不带模型名:模型是场景级设置(实时字幕 / 听写各自在「翻译方式」菜单里选),这里只管接口。
    private func serviceTitle(_ method: TranslationMethod) -> String {
        switch method {
        case .system: String(localized: "系统翻译（离线）", bundle: .l10n)
        default: method.title
        }
    }

    /// 服务说明。AI 行说明接口在哪里配、模型在哪里选,其他服务用方式自带的说明。
    private func serviceDetail(_ method: TranslationMethod) -> String {
        switch method {
        case .llm: String(localized: "接口在 AI 服务 里配置；实时字幕 / 听写各自在「翻译方式」菜单里选模型", bundle: .l10n)
        default: method.detail
        }
    }

    @ViewBuilder
    private func status(_ method: TranslationMethod) -> some View {
        switch method {
        case .system:
            let statuses = Set([translation.systemStatus(for: settings.subtitleTarget), translation.systemStatus(for: settings.translateTarget)])
            if statuses == [.installed] {
                Tag(text: "已下载", color: DS.success)
            } else if statuses.contains(.needsDownload) {
                Tag(text: "语言包未下载", color: DS.warning)
            } else if statuses.contains(.unsupported) {
                Tag(text: "不支持当前语言", color: DS.warning)
            }
        case .provider(let provider):
            if app.translationProviders.isConfigured(provider) { Tag(text: "已配置", color: DS.success) } else { Tag(text: "未配置") }
        case .llm:
            if settings.llmConfigured { Tag(text: "已配置", color: DS.success) } else { Tag(text: "未配置") }
        }
    }

    private func configureHelp(_ method: TranslationMethod) -> String {
        switch method {
        case .system: String(localized: "查看和下载系统翻译语言包", bundle: .l10n)
        case .provider: String(localized: "填写密钥、测试连接", bundle: .l10n)
        case .llm: String(localized: "在 设置 › AI 服务 里配置接口和默认模型", bundle: .l10n)
        }
    }

    private func configureService(_ method: TranslationMethod) {
        switch method {
        case .system: navigation.showingSystemTranslation = true
        case .provider(let provider): navigation.configure(provider, useFor: nil)
        case .llm: navigation.pane = .ai
        }
    }

    /// 配置表单里「使用此服务」的初始勾选:正在用它的场景,加上从哪个场景进来配置的。
    private func usage(for provider: TranslationProvider) -> TranslationProviderSheet.Usage {
        TranslationProviderSheet.Usage(
            subtitles: settings.subtitleTranslationMethod == .provider(provider) || navigation.providerUse == .subtitles,
            dictation: settings.dictationTranslationMethod == .provider(provider) || navigation.providerUse == .dictation)
    }

    /// 保存时按勾选决定哪些场景用它;取消勾选正在用它的场景时退回系统翻译(不会停在一个没选的服务上)。
    private func apply(_ usage: TranslationProviderSheet.Usage, to provider: TranslationProvider) {
        let method = TranslationMethod.provider(provider)
        if usage.subtitles {
            settings.subtitleTranslationMethod = method
        } else if settings.subtitleTranslationMethod == method {
            settings.subtitleTranslationMethod = .system
        }
        if usage.dictation {
            settings.dictationTranslationMethod = method
        } else if settings.dictationTranslationMethod == method {
            settings.dictationTranslationMethod = .system
        }
    }

    /// 移除了正在使用的服务:该场景退回系统翻译(不会停在一个用不了的方式上)。
    private func providerRemoved(_ provider: TranslationProvider) {
        if settings.subtitleTranslationMethod == .provider(provider) { settings.subtitleTranslationMethod = .system }
        if settings.dictationTranslationMethod == .provider(provider) { settings.dictationTranslationMethod = .system }
    }
}
