import AppKit
import AVFoundation
import ApplicationServices

/// 麦克风与辅助功能权限。系统音频录制权限没有公开的查询接口,第一次采集时由系统弹窗申请。
@MainActor @Observable
final class Permissions {
    private(set) var microphone: AVAuthorizationStatus = .notDetermined
    private(set) var accessibility = false
    private var timer: Timer?

    init() { refresh() }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
    }

    var allRequiredGranted: Bool { microphone == .authorized && accessibility }

    /// 权限页打开时轮询,用户在系统设置里打开开关后界面自动刷新。
    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func requestMicrophone() {
        switch microphone {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        default:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        refresh()
    }

    func openSystemAudioSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
