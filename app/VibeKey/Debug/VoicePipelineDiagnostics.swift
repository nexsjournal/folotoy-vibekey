import AppKit
import AVFoundation

/// 显式诊断入口：用真实硬件检查采音，用指定测试音频检查实际模型和翻译服务。
/// 普通诊断不打开窗口或输入文字；显式验收参数仅向前台 TextEdit 写入测试结果。硬件采音仅记录统计量。
@MainActor
enum VoicePipelineDiagnostics {
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--diagnose-voice-pipeline"),
              arguments.indices.contains(index + 2) else { return false }
        let audio = URL(fileURLWithPath: arguments[index + 1])
        let output = URL(fileURLWithPath: arguments[index + 2])
        Task {
            let app = AppState()
            var result: [String: Any] = ["model": app.settings.dictationModelID, "stage": "connecting"]
            func save() {
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: output, options: .atomic)
                }
            }
            save()
            app.deviceLink.start()
            let requireWiFi = arguments.contains("--require-wifi")
            let requireBLE = arguments.contains("--require-ble")
            if requireBLE {
                // BLE 与 USB 互斥：先释放串口，让 DeviceLink 扫描蓝牙。
                app.deviceLink.suspendUSB(allowBluetooth: true)
            }
            let deadline = ContinuousClock.now + .seconds(requireWiFi || requireBLE ? 25 : 8)
            while (requireWiFi ? !app.deviceLink.wifiReady
                   : requireBLE ? app.deviceLink.connection != .ble
                   : app.deviceLink.connection == .disconnected),
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if requireWiFi {
                // 只暂停本进程 USB，验证 TLS 握手、切换与真实无线采音；不读取或输出配网密钥。
                app.deviceLink.suspendUSB()
                try? await Task.sleep(for: .milliseconds(1200))
                result["wirelessPassed"] = app.deviceLink.connection == .wifi
            }
            if requireBLE {
                result["wirelessPassed"] = app.deviceLink.connection == .ble
            }
            result["deviceConnected"] = app.deviceLink.connection != .disconnected
            result["transport"] = String(describing: app.deviceLink.connection)
            do {
                let source = PassportMicSource(link: app.deviceLink)
                let probe = SampleStatistics()
                source.onSamples = { probe.append($0) }
                let requestedLinkUnavailable = (requireWiFi && app.deviceLink.connection != .wifi)
                    || (requireBLE && app.deviceLink.connection != .ble)
                if requestedLinkUnavailable {
                    throw NSError(domain: "VoiceDiagnostics", code: 3, userInfo: [NSLocalizedDescriptionKey: "Requested wireless link is unavailable"])
                }
                try source.start()
                try? await Task.sleep(for: .seconds(2))
                source.stop()
                result["microphone"] = probe.snapshot()
            } catch { result["microphoneError"] = error.localizedDescription }
            app.deviceLink.stop()
            result["stage"] = "recognizing"
            save()
            do {
                guard app.models.isInstalled(app.settings.dictationModelID),
                      let engine = app.engines.engine(for: app.settings.dictationModelID) else {
                    throw NSError(domain: "VoiceDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected model is unavailable"])
                }
                let file = try AVAudioFile(forReading: audio)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw NSError(domain: "VoiceDiagnostics", code: 2)
                }
                try file.read(into: buffer)
                let samples = AudioConverter().convert(buffer)
                try await engine.prepare()
                let session = try await engine.makeSession(.init(purpose: .dictation, language: app.settings.language, vocabulary: []))
                for offset in stride(from: 0, to: samples.count, by: 1600) {
                    session.feed(Array(samples[offset..<min(offset + 1600, samples.count)]))
                }
                let text = await session.finish()
                result["fixtureTranscript"] = text
                result["recognitionPassed"] = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } catch { result["recognitionError"] = error.localizedDescription }
            result["stage"] = "translating"
            save()
            do {
                let text = try await app.translation.translateDictation("你好，世界。")
                result["translation"] = text
                result["translationPassed"] = !text.isEmpty && text != "你好，世界。"
            } catch { result["translationError"] = error.localizedDescription }
            // 显式验收参数只允许把公开测试音频的结果写进前台 TextEdit 测试文稿。
            // 普通诊断不会写任何应用，也不会向聊天发送消息。
            if arguments.contains("--paste-fixture-to-textedit") {
                let target = NSWorkspace.shared.frontmostApplication
                result["pasteTarget"] = target?.bundleIdentifier ?? "none"
                if let target, target.bundleIdentifier == "com.apple.TextEdit",
                   let transcript = result["fixtureTranscript"] as? String {
                    let translation = result["translation"] as? String ?? "unavailable"
                    let inserter = TextInserter()
                    let outcome = await inserter.insert("ASR: \(transcript)\nTRANSLATE: \(translation)", target: target)
                    result["textEditInsertion"] = String(describing: outcome)
                    try? await Task.sleep(for: .seconds(1))
                    // 保持输入器存活到它恢复用户剪贴板后，测试入口也必须遵守剪贴板恢复约定。
                    withExtendedLifetime(inserter) {}
                }
            }
            result["stage"] = "complete"
            save()
            NSApp.terminate(nil)
        }
        return true
    }

    /// 音频回调可以跨线程；仅保留采样数、能量和峰值，不保留或识别现场声音。
    private nonisolated final class SampleStatistics: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var energy: Double = 0
        private var peak: Float = 0
        nonisolated func append(_ samples: [Float]) {
            lock.withLock {
                count += samples.count
                for sample in samples { energy += Double(sample * sample); peak = max(peak, abs(sample)) }
            }
        }
        nonisolated func snapshot() -> [String: Any] {
            lock.withLock { ["samples": count, "rms": count == 0 ? 0 : sqrt(energy / Double(count)), "peak": peak] }
        }
    }
}
