import Foundation

/// 字幕翻译时序追踪(仅调试构建,环境变量 IB_CAPTION_TRACE=1 时打印到标准输出):
/// 记录每句出现、译文到达、暂定译文更新的时间,用来定位"译文跟不上"出在调用链哪一环。正式版是空操作。
nonisolated enum CaptionTrace {
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.environment["IB_CAPTION_TRACE"] != nil
    private static let start = Date()
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard enabled else { return }
        print(String(format: "[trace %7.2f] ", Date().timeIntervalSince(start)) + message())
        fflush(stdout)
        #endif
    }
}
