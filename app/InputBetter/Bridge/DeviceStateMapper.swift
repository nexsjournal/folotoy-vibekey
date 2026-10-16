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
            // 字幕页只在设备处于字幕模式时显示;听写 / 翻译模式下字幕在后台运行,空闲页带 LIVE 标记。
            if deviceMode == .sub, subtitlesRunning { return State(ui: .sub, mode: .sub, msg: subtitleApp) }
            return State(ui: .idle, mode: deviceMode, msg: subtitlesRunning ? "LIVE" : "")
        case .starting, .recording:
            return State(ui: .rec, mode: dictMode, msg: "")
        case .processing:
            return State(ui: .proc, mode: dictMode, msg: "")
        case .done(let result):
            return State(ui: .done, mode: dictMode, msg: result == .typed ? "TYPED" : "COPIED")
        case .failed(let failure):
            return State(ui: .err, mode: dictMode, msg: asciiError(failure))
        }
    }

    static func keyHints(state: DeviceUIState, deviceMode: DeviceMode, handsFree: Bool, translating: Bool,
                         up: KeyAction, down: KeyAction) -> Hints {
        switch state {
        case .rec:
            // 按住说话时 OK 仍是麦克风(松开结束);免提时 OK 是停止。长按下键取消。
            return Hints(ok: handsFree ? .stop : .mic, up: nil, down: .cancel)
        case .proc, .done, .err:
            return Hints(ok: nil, up: nil, down: nil)
        case .sub:
            return Hints(ok: .stop, up: .translate, down: .hide)
        case .list:
            return Hints(ok: .check, up: .up, down: .down)
        case .idle:
            if deviceMode == .sub { return Hints(ok: .play, up: .mode, down: nil) }
            return Hints(ok: .mic, up: up.deviceIcon, down: down.deviceIcon)
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
