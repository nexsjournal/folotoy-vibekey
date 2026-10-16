import SwiftUI

/// 词汇表:专有名词、人名、术语,帮助识别和润色写对。
struct VocabularyPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsSection(title: "词汇表", footer: "每行一个词，例如 Claude Code、SwiftUI、张三。Whisper 和 Apple Speech 会参考它识别，AI 润色也会按它纠正拼写。") {
            Card {
                TextEditor(text: $settings.vocabulary)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .frame(minHeight: 260)
                    .overlay(alignment: .topLeading) {
                        if settings.vocabulary.isEmpty {
                            Text("Claude Code\nSwiftUI\nInputBetter")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }
}
