import AppKit
import Carbon.HIToolbox

/// 向前台应用发送按键 / 组合键 / 短文本(需要辅助功能权限)。
/// 全 app 唯一的模拟按键实现:TextInserter 的 ⌘V、Passport 按键动作都走这里。
@MainActor
enum KeySender {
    static func press(_ keyCode: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 直接输入一段 ASCII 文本(不经过剪贴板,用于 "1" 这类短输入)。
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 执行一个按键动作;`pasteLast` 与 `nextMode` 需要调用方处理,这里返回 false。
    @discardableResult
    static func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .enter: press(kVK_Return)
        case .escape: press(kVK_Escape)
        case .undo: press(Int(KeyLayout.keyCode(for: "z") ?? CGKeyCode(kVK_ANSI_Z)), flags: .maskCommand)
        case .shiftTab: press(kVK_Tab, flags: .maskShift)
        case .tab: press(kVK_Tab)
        case .cmdEnter: press(kVK_Return, flags: .maskCommand)
        case .ctrlC: press(Int(KeyLayout.keyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C)), flags: .maskControl)
        case .approve:
            type("1")
            press(kVK_Return)
        case .none, .pasteLast, .nextMode, .appSwitcher:
            return false
        }
        return true
    }
}

/// 在当前键盘布局里查找某个字符对应的键码(Dvorak 等布局下 ⌘V 不在 ANSI V 位置)。
nonisolated enum KeyLayout {
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(character)
        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
