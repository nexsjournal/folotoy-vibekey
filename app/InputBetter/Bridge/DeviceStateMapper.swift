import Foundation

/// 纯函数:把 app 状态翻译成设备界面要显示的内容(state / mode / msg / 按键提示)。
/// 不持有任何对象,便于沿 `DeviceBridge.sync → DeviceStateMapper → DeviceLink.send*` 这条链单独测试。
enum DeviceStateMapper {
    struct State: Equatable {
        let ui: DeviceUIState
        let mode: DeviceMode
        let msg: String
    }

    /// 右侧三个键的提示图标(nil = 隐藏)。
    struct Hints: Equatable {
        let ok: DeviceIcon?
        let up: DeviceIcon?
        let down: DeviceIcon?
    }

    static func state(phase: DictationController.Phase, dictationMode: DictationController.Mode, deviceMode: DeviceMode,
                      subtitlesRunning: Bool, subtitleApp: String) -> State {
        let dictMode: DeviceMode = dictationMode == .translate ? .tr : .dict
        switch phase {
        case .idle:
            // 显示与按键分开:字幕在运行就显示字幕页(应用名 + 随声音跳动的均衡器),不管设备在哪个模式;
            // 按键含义仍由设备模式决定(见 keyHints 与 DeviceBridge),mode 字段如实上报当前模式。
            if subtitlesRunning { return State(ui: .sub, mode: deviceMode, msg: subtitleApp) }
            return State(ui: .idle, mode: deviceMode, msg: "")
        case .starting, .recording:
            return State(ui: .rec, mode: dictMode, msg: "")
        case .processing:
            return State(ui: .proc, mode: dictMode, msg: "")
        case .done(let result):
            return State(ui: .done, mode: dictMode, msg: asciiResult(result))
        case .failed(let failure):
            return State(ui: .err, mode: dictMode, msg: asciiError(failure))
        }
    }

    static func keyHints(state: DeviceUIState, deviceMode: DeviceMode, handsFree: Bool, canTranslate: Bool,
                         up: KeyAction, down: KeyAction) -> Hints {
        switch state {
        case .rec:
            // 按住说话时 OK 仍是麦克风(松开结束);免提时 OK 是停止。长按下键取消。
            return Hints(ok: handsFree ? .stop : .mic, up: nil, down: .cancel)
        case .proc:
            // 上一句还在处理:OK 暂不可用。仍显示麦克风,设备在 PROC 页把提示列画成禁用色,
            // 按下时给出"不可用"反馈(见 docs/device-ui.md),让用户知道这时说话不会被录下。
            return Hints(ok: .mic, up: nil, down: nil)
        case .done, .err:
            return Hints(ok: nil, up: nil, down: nil)
        case .sub:
            // 字幕模式:OK 结束字幕、上键开关翻译、下键收起字幕条;听写 / 翻译模式:OK 说话,上下键是 vibe 动作。
            if deviceMode == .sub { return Hints(ok: .stop, up: canTranslate ? .translate : nil, down: .hide) }
            return Hints(ok: .mic, up: up.deviceIcon, down: down.deviceIcon)
        case .list:
            return Hints(ok: .check, up: .up, down: .down)
        case .idle:
            if deviceMode == .sub { return Hints(ok: .play, up: .mode, down: nil) }
            return Hints(ok: .mic, up: up.deviceIcon, down: down.deviceIcon)
        }
    }

    /// 完成页下方的文字(ASCII,最长 23 字节)。翻译 / 润色失败退回原文时说明没处理,原因在 Mac 的胶囊上看。
    static func asciiResult(_ result: DictationResult) -> String {
        switch result {
        case .typed: "TYPED"
        case .typedUntranslated: "NOT TRANSLATED"
        case .typedUnpolished: "NOT POLISHED"
        case .copied: "COPIED"
        }
    }

    /// 设备屏幕只能显示 ASCII,失败原因映射成短英文。
    static func asciiError(_ failure: DictationFailure) -> String {
        switch failure {
        case .noSpeech: "NO SPEECH"
        case .noModel: "NO MODEL"
        case .translationUnavailable: "NO TRANSLATE"
        case .engineNotReady: "ENGINE ERROR"
        case .other: "ERROR"
        }
    }
}
