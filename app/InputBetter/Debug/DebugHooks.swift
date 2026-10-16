#if DEBUG
import AppKit
import AVFoundation

/// 仅调试构建可用的启动钩子(环境变量),用于自动化检查,不进入正式版本:
/// - IB_DOWNLOAD=id1,id2       启动后下载这些模型;
/// - IB_TRANSCRIBE_FILE=path   用 IB_TRANSCRIBE_MODELS(逗号分隔)里的模型识别该音频文件,打印结果与耗时后退出;
/// - IB_SHOW_PILL=1            直接显示状态条(跳过引导);
/// - IB_SUBTITLE_APP=bundleID  启动后直接对该应用开字幕;
/// - IB_SHOW_TRANSCRIPT=1      打开字幕记录窗口(IB_TRANSCRIPT_TAB=summary 打开「总结」页);
/// - IB_SUMMARIZE_AFTER=秒      启动后过这么多秒触发一次「立即总结」;
/// - IB_DEMO_CAPTIONS=1        用示例双语字幕显示字幕条(不采集音频),检查排版;
/// - IB_SWITCH_LANGUAGE=en|zh-Hans  启动 2 秒后切换界面语言(检查即时切换)。
@MainActor
enum DebugHooks {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func run(app: AppState) {
        if let ids = env["IB_DOWNLOAD"] {
            for id in ids.split(separator: ",") { app.models.download(String(id)) }
        }
        if let path = env["IB_TRANSCRIBE_FILE"] {
            let ids = (env["IB_TRANSCRIBE_MODELS"] ?? app.settings.dictationModelID).split(separator: ",").map(String.init)
            Task { await transcribe(path: path, modelIDs: ids, app: app) }
        }
        if env["IB_SHOW_PILL"] != nil { app.showPill() }
        if let code = env["IB_SWITCH_LANGUAGE"], let target = AppLanguage(rawValue: code) {
            let previous = AppLanguage.saved
            Task {
                try? await Task.sleep(for: .seconds(2))
                app.language.set(target)
                // 只用于检查,不改变用户保存的选择。
                AppLanguage.save(previous)
            }
        }
        if let bid = env["IB_SUBTITLE_APP"] {
            let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bid }?.localizedName ?? bid
            app.startCaptions(AudioApp(bundleID: bid, name: name, pid: 0, isPlaying: true))
        }
        if env["IB_DEMO_CAPTIONS"] != nil { showDemoCaptions(app: app) }
        if env["IB_SHOW_TRANSCRIPT"] != nil { app.windows.showTranscript() }
        if let seconds = env["IB_SUMMARIZE_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                app.summarizer.summarizeNow()
            }
        }
    }

    private static func showDemoCaptions(app: AppState) {
        let start = Date().addingTimeInterval(-170)
        var sample = CaptionTranscript(appName: "Google Chrome", startedAt: start)
        let lines: [(String, String?)] = [
            ("We know the equation of a quadratic equation.", "我们知道二次方程的解。"),
            ("How to solve that.", "如何解这个方程。"),
            ("We know.", "我们知道。"),
            ("The rules of a right triangle, we know many, many rules of math and geometry and logic and science.", "直角三角形的性质，我们知道很多很多数学、几何、逻辑和科学方面的规律。"),
            ("We have puzzle games that we could give it.", nil),
        ]
        for (i, line) in lines.enumerated() {
            let entry = CaptionTranscript.Entry(time: start.addingTimeInterval(Double(150 + i * 4)), text: line.0, translation: line.1)
            sample.append(entry)
        }
        app.settings.subtitleTranslate = true
        app.subtitles.debugShow(sample, partial: "Constraint, constraint")
    }

    private static func transcribe(path: String, modelIDs: [String], app: AppState) async {
        guard let samples = loadSamples(path) else {
            print("IBBENCH load failed: \(path)")
            exit(1)
        }
        print("IBBENCH audio \(String(format: "%.1f", Double(samples.count) / 16_000))s")
        for id in modelIDs {
            guard let engine = app.engines.engine(for: id) else { continue }
            do {
                let loadStart = Date()
                try await engine.prepare()
                let loadTime = Date().timeIntervalSince(loadStart)
                let options = ASROptions(purpose: .dictation, language: app.settings.language, vocabulary: app.settings.vocabularyTerms)
                let session = try await engine.makeSession(options)
                // 模拟实时输入:按 100 ms 一块送入,最后计时 finish(即松开快捷键后的等待时间)。
                var i = 0
                while i < samples.count {
                    let end = min(i + 1_600, samples.count)
                    session.feed(Array(samples[i..<end]))
                    i = end
                }
                // 等处理队列消化完已送入的音频,只计松开后的识别时间。
                try? await Task.sleep(for: .seconds(Double(samples.count) / 16_000 * 0.5 + 2))
                let finishStart = Date()
                let text = await session.finish()
                print("IBBENCH \(id) load=\(String(format: "%.2f", loadTime))s finish=\(String(format: "%.2f", Date().timeIntervalSince(finishStart)))s text=\(text)")
            } catch {
                print("IBBENCH \(id) error=\(error.localizedDescription)")
            }
        }
        exit(0)
    }

    private static func loadSamples(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        return AudioConverter().convert(buffer)
    }
}
#endif
