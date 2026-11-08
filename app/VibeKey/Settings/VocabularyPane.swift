import SwiftUI

/// 词汇表:专有名词、人名、术语,帮助识别和润色写对。
struct VocabularyPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsSection(title: "词汇表", footer: "每行一个词。可用「正式写法 = 常见误识别」指定纠正，例如 DeepSeek = DIPSEEK, deep seek, 迪普希克。识别后立即替换，不增加出字延迟；Whisper 和 Apple Speech 也会参考正式写法。") {
            Card {
                TextEditor(text: $settings.vocabulary)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .frame(minHeight: 260)
                    .overlay(alignment: .topLeading) {
                        if settings.vocabulary.isEmpty {
                            Text("Claude Code\nSwiftUI\nDeepSeek = DIPSEEK, deep seek, 迪普希克\nVibeKey")
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
