import SwiftUI

/// 界面语言选择,切换后立即生效。设置页和欢迎页共用。
struct LanguagePicker: View {
    let language: LanguageState

    var body: some View {
        Picker("", selection: Binding(get: { language.language }, set: { language.set($0) })) {
            ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// 根视图包装:注入当前语言的 locale,语言变化时整体重建,让所有文字(包括模型、枚举里的)一起刷新。
struct LocalizedRoot<Content: View>: View {
    let language: LanguageState
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.locale, language.locale)
            .id(language.locale.identifier)
    }
}
