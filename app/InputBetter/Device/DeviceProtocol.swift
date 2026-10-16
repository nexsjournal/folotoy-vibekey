import Foundation

// MARK: - 设备 → Mac

/// `hello` 回复:固件名(必须是 inputbetter)、协议版本、固件版本、本次上电的随机 boot ID。
nonisolated struct DeviceHello: Equatable, Sendable {
    var firmware: String
    var protocolVersion: Int
    var version: String
    var boot: String
    /// 固件构建标识(ELF SHA256 前 8 位);旧固件没有这个字段时为空。
    var build: String = ""
}

/// `key` 原始按键事件;语义(按住说话、切换模式等)由上层解释。
nonisolated struct DeviceKeyReport: Equatable, Sendable {
    var key: DeviceKey
    var event: DeviceKeyEvent
    /// 本次上电后单调递增;缺失时不参与去重。
    var seq: Int?
    var boot: String
    /// 这次按压用于关闭设备上的 agent 通知层(线上 `"ack":1`,同一次按压的 down/up/long 都带)。
    /// 上层应忽略它的常规动作。
    var ack: Bool = false
}

/// `bat` 电量上报(hello 之后及每 60 秒)。
nonisolated struct DeviceBatteryReport: Equatable, Sendable {
    /// 0...100;设备读不到时为 nil(线上为 -1)。
    var percent: Int?
    /// 毫伏;读不到时为 nil。
    var millivolts: Int?
    var charging: Bool
}

/// 设备上行的 JSON Lines 消息,定义见 docs/protocol.md「设备 → Mac」。
nonisolated enum DeviceMessage: Equatable, Sendable {
    case hello(DeviceHello)
    case key(DeviceKeyReport)
    case battery(DeviceBatteryReport)
    case pong

    static let firmwareName = "inputbetter"
    static let protocolVersion = 1

    private static let marker = #"{"t":"#

    /// USB 与 ESP-IDF 日志共用通道,只从 `{"t":` 处开始解析;日志、未知类型、缺字段的消息返回 nil。
    static func parse(_ line: String) -> DeviceMessage? {
        guard let start = line.range(of: marker) else { return nil }
        var json = line[start.lowerBound...]
        if let end = json.lastIndex(of: "}") {
            json = json[...end]
        } else {
            return nil
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let type = object["t"] as? String
        else {
            return nil
        }

        func string(_ key: String) -> String? { object[key] as? String }
        func int(_ key: String) -> Int? {
            guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.intValue
        }

        switch type {
        case "hello":
            guard let firmware = string("fw") else { return nil }
            return .hello(DeviceHello(
                firmware: firmware,
                protocolVersion: int("proto") ?? 0,
                version: string("ver") ?? "",
                boot: string("boot") ?? "",
                build: string("build") ?? ""
            ))
        case "key":
            guard let key = string("k").flatMap(DeviceKey.init(rawValue:)),
                  let event = string("e").flatMap(DeviceKeyEvent.init(rawValue:))
            else {
                return nil
            }
            return .key(DeviceKeyReport(
                key: key, event: event, seq: int("seq"), boot: string("boot") ?? "", ack: (int("ack") ?? 0) > 0
            ))
        case "bat":
            let percent = int("soc").flatMap { (0...100).contains($0) ? $0 : nil }
            let millivolts = int("mv").flatMap { $0 > 0 ? $0 : nil }
            return .battery(DeviceBatteryReport(percent: percent, millivolts: millivolts, charging: (int("chg") ?? 0) > 0))
        case "pong":
            return .pong
        default:
            return nil
        }
    }
}

// MARK: - Mac → 设备

/// Mac 下发的命令,定义见 docs/protocol.md「Mac → 设备」。编码为一行扁平 JSON + `\n`。
nonisolated enum HostCommand: Equatable, Sendable {
    case hello
    case ping
    case bye
    /// `clock`:Mac 本地时间 = Unix 秒 + 时区偏移,见 `HostCommand.localClock()`。
    case config(DeviceConfig, clock: Int)
    case state(DeviceUIState, mode: DeviceMode, msg: String)
    case level(Int)
    case mic(Bool)
    /// 屏幕底部三个键的提示文字;空字符串表示该键无动作。
    case keys(ok: String, up: String, down: String)
    /// 编程 Agent 通知,`msg` 为来源名(如 "Claude Code")。
    case agent(DeviceAgentEvent, msg: String)
    /// 列表页(如切换应用):最多 6 行可见,`top` 为第一行在完整列表中的下标,`sel` 为选中项的绝对下标。
    case list(title: String, sel: Int, total: Int, top: Int, items: [String])

    /// 设备屏幕文本字段(msg、engine)的最大字节数。
    static let textMaxBytes = 23
    /// 按键提示(`keys` 命令各字段)的最大字节数。
    static let keyHintMaxBytes = 11
    /// 列表页一屏最多显示的行数。
    static let listVisibleRows = 6

    /// 列表可见窗口的起始下标:尽量让选中项居中,并且不越过列表末尾。
    static func listTop(total: Int, selected: Int) -> Int {
        let rows = listVisibleRows
        return min(max(0, selected - rows / 2), max(0, total - rows))
    }

    var name: String {
        switch self {
        case .hello: "hello"
        case .ping: "ping"
        case .bye: "bye"
        case .config: "config"
        case .state: "state"
        case .level: "level"
        case .mic: "mic"
        case .keys: "keys"
        case .agent: "agent"
        case .list: "list"
        }
    }

    /// 不含换行的 JSON 文本;字段顺序固定,`cmd` 在最前。
    var line: String {
        var fields: [(String, FlatJSON.Value)] = [("cmd", .string(name))]
        switch self {
        case .hello, .ping, .bye:
            break
        case .config(let config, let clock):
            fields.append(("mic", .int(config.passportMic ? 1 : 0)))
            fields.append(("engine", .string(DeviceText.ascii(config.engine, maxBytes: Self.textMaxBytes))))
            fields.append(("screen_off", .int(max(0, config.screenOff))))
            fields.append(("clock", .int(max(0, clock))))
            fields.append(("sound", .int(config.sound ? 1 : 0)))
        case .state(let st, let mode, let msg):
            fields.append(("st", .string(st.rawValue)))
            fields.append(("mode", .string(mode.rawValue)))
            fields.append(("msg", .string(DeviceText.ascii(msg, maxBytes: Self.textMaxBytes))))
        case .level(let v):
            fields.append(("v", .int(min(max(v, 0), 100))))
        case .mic(let on):
            fields.append(("on", .int(on ? 1 : 0)))
        case .keys(let ok, let up, let down):
            fields.append(("ok", .string(DeviceText.ascii(ok, maxBytes: Self.keyHintMaxBytes))))
            fields.append(("up", .string(DeviceText.ascii(up, maxBytes: Self.keyHintMaxBytes))))
            fields.append(("down", .string(DeviceText.ascii(down, maxBytes: Self.keyHintMaxBytes))))
        case .agent(let ev, let msg):
            fields.append(("ev", .string(ev.rawValue)))
            fields.append(("msg", .string(DeviceText.ascii(msg, maxBytes: Self.textMaxBytes))))
        case .list(let title, let sel, let total, let top, let items):
            fields.append(("title", .string(DeviceText.ascii(title, maxBytes: Self.textMaxBytes))))
            fields.append(("sel", .int(max(0, sel))))
            fields.append(("n", .int(max(0, total))))
            fields.append(("top", .int(max(0, top))))
            for (i, item) in items.prefix(Self.listVisibleRows).enumerated() {
                fields.append(("i\(i)", .string(DeviceText.ascii(item, maxBytes: Self.textMaxBytes))))
            }
        }
        return FlatJSON.encode(fields)
    }

    /// 线上字节:JSON + `\n`。
    var data: Data {
        var data = Data(line.utf8)
        data.append(0x0A)
        return data
    }

    /// 设备时钟用的本地时间:Unix 秒 + 当前时区偏移(含夏令时)。
    static func localClock(now: Date = Date(), timeZone: TimeZone = .current) -> Int {
        Int(now.timeIntervalSince1970) + timeZone.secondsFromGMT(for: now)
    }
}

/// 扁平 JSON 对象编码:只有字符串和整数值,字段顺序按传入顺序。
nonisolated enum FlatJSON {
    enum Value: Equatable, Sendable {
        case string(String)
        case int(Int)
    }

    static func encode(_ fields: [(String, Value)]) -> String {
        var out = "{"
        for (i, (key, value)) in fields.enumerated() {
            if i > 0 { out += "," }
            out += quote(key)
            out += ":"
            switch value {
            case .string(let s): out += quote(s)
            case .int(let n): out += String(n)
            }
        }
        out += "}"
        return out
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
