import SwiftUI

/// AI 模型菜单项(听写润色、AI 翻译、字幕总结各自选模型时共用):
/// 「默认模型(xxx)」+ AI 服务提供的模型(LLMModelCatalog,太多时其余放进「更多模型」)+ 刷新。
/// 接口和 Key 只在 设置 › AI 服务 里配置一次;这里只选模型。
struct LLMModelMenuItems: View {
    /// 当前选中的模型:"" = 默认模型;nil = 都不勾(如翻译方式当前不是 AI)。
    let selected: String?
    let catalog: LLMModelCatalog
    let settings: AppSettings
    let onSelect: (String) -> Void

    /// 直接列出的模型数,其余放进「更多模型」。
    private static let inlineModels = 8

    var body: some View {
        option("", title: String(localized: "默认模型（\(settings.llmModel)）", bundle: .l10n))
        let models = catalog.chatModels.filter { $0 != settings.llmModel }
        // 选过、但不在列表里的模型(列表拉取失败或已下线)也显示出来,不会"选了看不见"。
        if let selected, !selected.isEmpty, selected != settings.llmModel, !models.contains(selected) {
            option(selected, title: selected)
        }
        ForEach(models.prefix(Self.inlineModels), id: \.self) { option($0, title: $0) }
        if models.count > Self.inlineModels {
            Menu("更多模型") {
                ForEach(models.dropFirst(Self.inlineModels), id: \.self) { option($0, title: $0) }
            }
        }
        // 拉取失败且没有可选模型时说明原因(置灰的菜单项,不可点),否则菜单里只剩「默认模型」看不出为什么。
        // 服务端错误可能很长(带响应正文),菜单项里截断显示。
        if let error = catalog.error, models.isEmpty {
            Button {} label: { Text(verbatim: String(localized: "无法获取模型列表：\(Self.brief(error))", bundle: .l10n)) }
                .disabled(true)
        }
        Button(catalog.loading ? LocalizedStringKey("正在获取模型列表…") : LocalizedStringKey("刷新模型列表")) { catalog.refresh() }
            .disabled(catalog.loading)
    }

    /// 菜单项里显示的错误原因:最多 60 个字符,超出部分用省略号。
    private static func brief(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    private func option(_ model: String, title: String) -> some View {
        Toggle(isOn: Binding(get: { selected == model }, set: { _ in onSelect(model) })) { Text(verbatim: title) }
    }
}
