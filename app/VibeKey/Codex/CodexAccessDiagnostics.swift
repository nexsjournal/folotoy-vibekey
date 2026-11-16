import AppKit
import ApplicationServices

/// 在正式签名 App 自身的进程里检查权限与只读目标；不启动设备服务，不录音或发送按键。
@MainActor
enum CodexAccessDiagnostics {
    /// 显式传入诊断参数时，将脱敏状态写入指定文件后退出；普通启动完全不执行。
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--diagnose-codex-access"),
              arguments.indices.contains(index + 1) else { return false }
        let output = URL(fileURLWithPath: arguments[index + 1])
        Task {
            let settings = AppSettings()
            var result: [String: Any] = [
                "trusted": AXIsProcessTrusted(),
                "bundleID": Bundle.main.bundleIdentifier ?? "",
                "appPath": Bundle.main.bundleURL.path,
                "targetBundleID": settings.deviceTargetBundleID
            ]
            var preparedDeviceTarget = false
            do {
                if let flag = arguments.firstIndex(of: "--followup-thread"), arguments.indices.contains(flag + 1),
                   let thread = UUID(uuidString: arguments[flag + 1]) {
                    let coordinator = CodexActionCoordinator(adapter: AccessibilityCodexDesktopAdapter())
                    try await CodexThreadNavigator(clipboard: TextInserter(), codex: coordinator).open(thread)
                    result["followupReady"] = true
                }
                if arguments.contains("--prepare-device-target") {
                    let inputTarget = DeviceInputTarget(settings: settings)
                    let target = try await inputTarget.prepare()
                    preparedDeviceTarget = true
                    result["targetFound"] = true
                    result["preparedTarget"] = target.bundleIdentifier ?? ""
                    result["targetPid"] = target.processIdentifier
                    result["targetFrontmost"] =
                        NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
                    if let binding = inputTarget.binding {
                        switch binding.input {
                        case .accessibility:
                            result["inputMode"] = "accessibility"
                        case .visual:
                            result["inputMode"] = "visual"
                        }
                    }
                }
                // 通用目标已经验证时不要再执行 Codex 专用检查；后者找不到 Codex 输入框时
                // 会覆盖刚取得的微信 / 普通应用成功结果，造成诊断误报。
                if !preparedDeviceTarget {
                    if let snapshot = try await AccessibilityCodexDesktopAdapter().inspectTarget() {
                        result["targetFound"] = true
                        result["frontmost"] = snapshot.isFrontmost
                        result["unlocked"] = snapshot.isUnlocked
                        result["inputEmpty"] = snapshot.inputIsEmpty
                        result["inputCharacters"] = snapshot.inputText.count
                        result["runState"] = String(describing: snapshot.runState)
                        result["approvalPending"] = snapshot.hasPendingApproval
                        result["canSend"] = snapshot.canSend
                    } else {
                        result["targetFound"] = false
                    }
                }
            } catch {
                result["error"] = String(describing: error)
            }
            result["axSummary"] = AccessibilityCodexDesktopAdapter.debugTreeSummary()
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
            } catch {
                NSLog("Codex access diagnostic could not write result: %@", String(describing: error))
            }
            NSApp.terminate(nil)
        }
        return true
    }
}
