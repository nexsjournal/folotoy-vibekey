import SwiftUI

/// 字幕条标题栏上的翻译控件:
/// - 「译」标签:点一下就翻译成默认语言(设置 › 实时字幕 › 默认翻译成),再点一下关闭 —— 不用每次选语言;
///   旁边的 ⌄ 换语言(选的语言同时成为默认语言,下次点「译」就用它)。开关只对本场字幕有效。
/// - 翻译方式标签:选翻译方式和 AI 模型,只在开启翻译后出现。
/// - 原文行数标签(SourceLinesChip):翻译时原文显示几行,只在开启翻译后出现。
/// 只读状态、发意图:开关交给 SubtitleController,语言 / 方式写进设置(AppState 监听后重新翻译最新一句)。
struct TranslationTargetChip: View {
    let controller: SubtitleController
    @Bindable var settings: AppSettings
    let onSettings: () -> Void

    private var enabled: Bool { controller.translationEnabled }

    /// 标签上的目标语言:「自动」没有信息量,写成「自动 → 简体中文」(自动模式最常见的方向是译成主语言)。
    private var targetLabel: String {
        let target = settings.subtitleTarget
        guard target == .auto else { return target.title }
        return "\(target.title) → \(TargetLanguage.autoPair().primary.title)"
    }

    /// 悬停提示里写全自动模式的规则。
    private var targetDescription: String {
        settings.subtitleTarget == .auto ? TargetLanguage.autoSummary : settings.subtitleTarget.title
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { controller.toggleTranslation() } label: {
                Text(verbatim: enabled ? String(localized: "译 · \(targetLabel)", bundle: .l10n)
                                       : String(localized: "译", bundle: .l10n))
                    .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(enabled ? String(localized: "正在翻译成 \(targetDescription)，点一下关闭翻译", bundle: .l10n)
                          : String(localized: "点一下翻译成 \(targetDescription)", bundle: .l10n))
            .accessibilityLabel(enabled ? String(localized: "关闭翻译", bundle: .l10n)
                                        : String(localized: "翻译成 \(targetLabel)", bundle: .l10n))
            Rectangle().fill(.white.opacity(enabled ? 0.25 : 0.12)).frame(width: 1, height: 10)
            Menu {
                Section("翻译成") {
                    // 没开翻译时不勾任何语言(勾着会让人以为已经在翻译)。选了语言 = 开翻译;
                    // 先写设置再开:SubtitleController 会发现设置和刚翻译时一样,不会把同一句翻两次。
                    TargetLanguageMenuItems(selected: enabled ? settings.subtitleTarget : nil) { language in
                        settings.subtitleTarget = language
                        controller.setTranslationEnabled(true)
                    }
                }
                Divider()
                Button("实时字幕设置…", action: onSettings)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "选择翻译成的语言", bundle: .l10n))
            .accessibilityLabel(String(localized: "选择翻译成的语言", bundle: .l10n))
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.45))
        .background(Capsule().strokeBorder(.white.opacity(enabled ? 0.3 : 0.15)))
        .fixedSize()
    }
}

struct TranslationMethodChip: View {
    let translation: TranslationService
    let catalog: LLMModelCatalog
    @Bindable var settings: AppSettings
    /// 最近一次翻译失败的原因(额度用完、密钥失效等):标签上显示 ⚠,悬停可见原因,提醒用户换一种方式。
    var error: String?
    let onConfigure: (TranslationProvider) -> Void
    let onConfigureSystem: () -> Void
    let onConfigureLLM: () -> Void
    let onSettings: () -> Void

    private var method: TranslationMethod { settings.subtitleTranslationMethod }
    private var reason: String? { translation.unavailableReason(method) ?? error }

    var body: some View {
        Menu {
            TranslationMethodMenuItems(current: method, translation: translation, catalog: catalog, settings: settings,
                                       onSelect: { settings.subtitleTranslationMethod = $0 },
                                       onConfigure: onConfigure, onConfigureSystem: onConfigureSystem,
                                       onConfigureLLM: onConfigureLLM, onSettings: onSettings)
        } label: {
            HStack(spacing: 3) {
                if reason != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.warning) }
                Text(verbatim: method.shortLabel(model: translation.modelName(method)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7)
            }
            .chipStyle(active: true)
        }
        .chipMenuStyle()
        .help(reason ?? String(localized: "翻译方式：\(method.shortLabel(model: translation.modelName(method)))", bundle: .l10n))
        .accessibilityLabel(String(localized: "翻译方式：\(method.shortLabel(model: translation.modelName(method)))", bundle: .l10n))
    }
}

/// 翻译时原文显示几行的快捷切换(和 设置 › 实时字幕 › 翻译时原文行数 是同一个设置):
/// 「原文 2 行 ⌄」/「只看译文 ⌄」,菜单里选 不显示 / 1 / 2 / 3 行。只在开启翻译后出现(不翻译时原文固定 2 行)。
struct SourceLinesChip: View {
    @Bindable var settings: AppSettings

    private var label: String {
        settings.subtitleSourceLines == 0
            ? String(localized: "只看译文", bundle: .l10n)
            : String(localized: "原文 \(settings.subtitleSourceLines) 行", bundle: .l10n)
    }

    var body: some View {
        Menu {
            Picker(selection: $settings.subtitleSourceLines) {
                Text("不显示原文").tag(0)
                ForEach(1...3, id: \.self) { Text(String(localized: "原文 \($0) 行", bundle: .l10n)).tag($0) }
            } label: {
                Text("翻译时原文行数")
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: label).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7)
            }
            .chipStyle(active: true)
        }
        .chipMenuStyle()
        .help(String(localized: "翻译时原文显示几行（不显示时只看译文）", bundle: .l10n))
        .accessibilityLabel(String(localized: "翻译时原文行数：\(label)", bundle: .l10n))
    }
}

private extension View {
    func chipStyle(active: Bool) -> some View {
        font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(active ? 0.8 : 0.4))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().strokeBorder(.white.opacity(active ? 0.3 : 0.15)))
            .contentShape(Capsule())
    }

    func chipMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
