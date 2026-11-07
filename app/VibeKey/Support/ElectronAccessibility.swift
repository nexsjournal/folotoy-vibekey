import ApplicationServices

/// Electron 官方提供给外部辅助工具的入口。开启后才会完整暴露 Chromium 的编辑器和控件树。
/// 调用方按进程缓存成功结果；不周期性切换模式，不启用 VoiceOver，也不更改系统授权。
@MainActor
enum ElectronAccessibility {
    @discardableResult
    static func enable(processID: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(processID)
        let attribute = "AXManualAccessibility" as CFString
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, attribute, &value) == .success,
           let value, CFGetTypeID(value) == CFBooleanGetTypeID(), CFBooleanGetValue(value as! CFBoolean) { return true }
        let result = AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue)
        if result == .success { Log.codex.info("Electron manual accessibility enabled") }
        return result == .success
    }
}
