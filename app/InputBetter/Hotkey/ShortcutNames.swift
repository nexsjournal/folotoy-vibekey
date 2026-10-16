import KeyboardShortcuts

/// 可在设置里录制的组合键。
extension KeyboardShortcuts.Name {
    /// 听写:按住说话,轻按免提。默认 ⌥空格。
    static let dictate = Self("dictate", initial: .init(.space, modifiers: [.option]))
    /// 翻译听写:说完翻译成目标语言再输入。
    static let translateDictate = Self("translateDictate", initial: .init(.space, modifiers: [.option, .shift]))
    /// 开关实时字幕。
    static let toggleSubtitles = Self("toggleSubtitles", initial: .init(.s, modifiers: [.option, .shift]))
}
