import SwiftUI

/// 设备提示图标在 Mac 界面里对应的 SF Symbol(示意图与设备上的 Material 图标含义一致)。
extension DeviceIcon {
    var sfSymbol: String {
        switch self {
        case .enter: "return"
        case .esc: "escape"
        case .undo: "arrow.uturn.backward"
        case .stab: "arrow.left.to.line"
        case .tab: "arrow.right.to.line"
        case .send: "paperplane.fill"
        case .stop: "stop.fill"
        case .cancel: "xmark.circle"
        case .check: "checkmark"
        case .repeat: "arrow.clockwise"
        case .mode: "arrow.up.arrow.down"
        case .apps: "square.grid.2x2"
        case .mic: "mic.fill"
        case .translate: "character.bubble"
        case .hide: "eye.slash"
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .play: "play.fill"
        case .open: "arrow.up.right.square"
        }
    }
}
