import AppKit
import Carbon.HIToolbox

/// 向前台应用发送按键 / 组合键(需要辅助功能权限)。
/// 全 app 唯一的模拟按键实现:TextInserter 的 ⌘V、Passport 按键动作都走这里。
@MainActor
enum KeySender {
    @discardableResult
    static func press(_ keyCode: Int, flags: CGEventFlags = [], processID: pid_t? = nil) -> Bool {
        // 测试宿主绝不向用户当前焦点发送真实按键。
        guard ProcessInfo.processInfo.environment["IB_TEST_MODE"] != "1" else { return false }
        if let processID, processID <= 0 { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        if let processID {
            // 发送到已核对的应用进程，避免焦点在最后一刻切换后把提交键送往其他应用。
            down.postToPid(processID)
            up.postToPid(processID)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    /// 执行一个按键动作;`pasteLast` 与 `nextMode` 需要调用方处理,这里返回 false。
    @discardableResult
    static func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .enter: press(kVK_Return)
        case .escape: press(kVK_Escape)
        case .codexSend, .codexStop:
            return false
        case .undo: press(Int(KeyLayout.keyCode(for: "z") ?? CGKeyCode(kVK_ANSI_Z)), flags: .maskCommand)
        // 退格 / 向后删除是固定位置的功能键,与键盘布局无关。
        case .backspace: press(kVK_Delete)
        case .forwardDelete: press(kVK_ForwardDelete)
        case .shiftTab: press(kVK_Tab, flags: .maskShift)
        case .tab: press(kVK_Tab)
        case .cmdEnter: press(kVK_Return, flags: .maskCommand)
        case .ctrlC: press(Int(KeyLayout.keyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C)), flags: .maskControl)
        // 旧版「1 + 回车」无法绑定审批请求,保留枚举只为读取旧设置,不再发送任何按键。
        case .approve, .none, .pasteLast, .nextMode, .appSwitcher:
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
