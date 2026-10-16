import KeyboardShortcuts

/// 把全局快捷键接到具体动作上。动作以闭包注入,本模块不依赖听写或字幕的实现。
/// 调用链:KeyboardShortcuts.onKeyDown/onKeyUp → Actions → DictationController / AppState。
@MainActor
final class HotkeyManager {
    struct Actions {
        var dictateDown: () -> Void
        var dictateUp: () -> Void
        var translateDown: () -> Void
        var translateUp: () -> Void
        var toggleSubtitles: () -> Void
    }

    private var actions: Actions?

    func start(_ actions: Actions) {
        self.actions = actions
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.actions?.dictateDown() }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.actions?.dictateUp() }
        KeyboardShortcuts.onKeyDown(for: .translateDictate) { [weak self] in self?.actions?.translateDown() }
        KeyboardShortcuts.onKeyUp(for: .translateDictate) { [weak self] in self?.actions?.translateUp() }
        KeyboardShortcuts.onKeyDown(for: .toggleSubtitles) { [weak self] in self?.actions?.toggleSubtitles() }
    }

    /// 显示在界面上的听写快捷键,如"⌥Space"。
    var dictateDescription: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? String(localized: "未设置", bundle: .l10n)
    }
}
