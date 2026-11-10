import Foundation

nonisolated struct DeviceWiFiStatus: Equatable, Sendable {
    let stage: String
    let host: String
    let address: String
    var ssid: String = ""
    var active: Int?
    var count: Int?
    var rssi: Int? = nil
    var networks: [DeviceWiFiNetwork] = []
}

nonisolated struct DeviceWiFiNetwork: Equatable, Sendable {
    var ssid: String
    var host: String
    var active: Bool
}

// MARK: - 设备 → Mac

/// `hello` 回复:固件名、协议版本、固件版本、本次上电的随机 boot ID。
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
    case wake
    case wifi(DeviceWiFiStatus)
    /// 离线页背景上传结果。`phase` 为 `start`（擦除完成）/ `done` / `clear`。
    case wallpaper(ok: Bool, phase: String)

    static let firmwareName = "vibekey"
    /// 0.1.7 及更早的固件沿用了上游 `inputbetter` 标识;新 app 继续接受,避免必须先刷机才能连上。
    static let legacyFirmwareNames: Set<String> = ["inputbetter"]
    static let protocolVersion = 1

    /// 握手时判断固件身份;新标识与旧标识都接受。
    static func acceptsFirmware(_ name: String) -> Bool {
        name == firmwareName || legacyFirmwareNames.contains(name)
    }

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
        case "wifi":
            guard let stage = string("stage") else { return nil }
            var networks: [DeviceWiFiNetwork] = []
            if let rows = object["networks"] as? [[String: Any]] {
                networks = rows.compactMap { row in
                    guard let ssid = row["ssid"] as? String else { return nil }
                    return DeviceWiFiNetwork(
                        ssid: ssid,
                        host: row["host"] as? String ?? "",
                        active: (row["active"] as? NSNumber)?.intValue == 1
                    )
                }
            }
            return .wifi(.init(
                stage: stage,
                host: string("host") ?? "",
                address: string("ip") ?? "",
                ssid: string("ssid") ?? "",
                active: int("active"),
                count: int("count"),
                rssi: int("rssi"),
                networks: networks
            ))
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
        case "wake":
            return .wake
        case "wallpaper":
            return .wallpaper(ok: (int("ok") ?? 0) > 0, phase: string("p") ?? "")
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
    /// Agent 用量首页;字符串已格式化,设备只排版。
    case usage(DeviceUsage)
    /// 字幕:应用名 + 当前原文 / 译文(UTF-8);`live` 表示末行还在变化。
    case caption(app: String, src: String, dst: String, live: Bool)
    /// 离线页背景：分块上传 240×320 RGB565，设备写入独立分区后重启。
    case wallpaperStart(size: Int, crc: UInt32)
    case wallpaperChunk(offset: Int, base64: String)
    case wallpaperFinish
    case wallpaperClear

    /// 设备屏幕文本字段(msg、engine)的最大字节数。
    static let textMaxBytes = 23
    /// 按键提示(`keys` 命令各字段)的最大字节数。
    static let keyHintMaxBytes = 11
    /// 列表页一屏最多显示的行数。
    static let listVisibleRows = 6
    /// 列表标题 / 行文本的 UTF-8 字节上限(设备端 12 px 中文字库两行内)。
    static let listTextMaxBytes = 47
    /// 字幕原文 / 译文各字段的 UTF-8 字节上限。
    static let captionMaxBytes = 180
    /// 字幕应用名上限。
    static let captionAppMaxBytes = 48
    /// 每块原始字节数；base64 后 384 字符，整行仍小于 511 字节。
    static let wallpaperChunkBytes = 288

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
        case .usage: "usage"
        case .caption: "caption"
        case .wallpaperStart, .wallpaperChunk, .wallpaperFinish, .wallpaperClear: "wallpaper"
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
            fields.append(("title", .string(DeviceText.utf8(title, maxBytes: Self.listTextMaxBytes))))
            fields.append(("sel", .int(max(0, sel))))
            fields.append(("n", .int(max(0, total))))
            fields.append(("top", .int(max(0, top))))
            for (i, item) in items.prefix(Self.listVisibleRows).enumerated() {
                fields.append(("i\(i)", .string(DeviceText.utf8(item, maxBytes: Self.listTextMaxBytes))))
            }
        case .usage(let usage):
            fields.append(("uapp", .string(DeviceText.ascii(usage.app, maxBytes: Self.textMaxBytes))))
            fields.append(("utoday", .string(DeviceText.ascii(usage.today, maxBytes: Self.textMaxBytes))))
            fields.append(("uweek", .string(DeviceText.ascii(usage.week, maxBytes: Self.textMaxBytes))))
            fields.append(("utotal", .string(DeviceText.ascii(usage.total, maxBytes: Self.textMaxBytes))))
            fields.append(("utab", .int(min(max(usage.tab, 0), 2))))
            if let left = usage.leftPercent {
                fields.append(("uquota", .int(1)))
                fields.append(("uleft", .int(min(max(left, 0), 100))))
            }
            fields.append(("ureset", .string(DeviceText.ascii(usage.reset, maxBytes: Self.keyHintMaxBytes))))
            fields.append(("uplan", .string(DeviceText.ascii(usage.plan, maxBytes: Self.keyHintMaxBytes))))
            if let credits = usage.credits {
                fields.append(("ucredit", .int(min(max(credits, 0), 255))))
            }
            if let fiveHour = usage.fiveHourLeftPercent {
                fields.append(("u5quota", .int(1)))
                fields.append(("u5left", .int(min(max(fiveHour, 0), 100))))
            }
            if !usage.fiveHourReset.isEmpty {
                fields.append(("u5reset", .string(DeviceText.ascii(usage.fiveHourReset, maxBytes: Self.keyHintMaxBytes))))
            }
            if !usage.panel1Label.isEmpty {
                fields.append(("u1l", .string(DeviceText.ascii(usage.panel1Label, maxBytes: Self.textMaxBytes))))
                fields.append(("u1v", .string(DeviceText.ascii(usage.panel1Value, maxBytes: Self.textMaxBytes))))
                if let percent = usage.panel1Percent {
                    fields.append(("u1p", .int(min(max(percent, 0), 100))))
                }
            }
            if !usage.panel2Label.isEmpty {
                fields.append(("u2l", .string(DeviceText.ascii(usage.panel2Label, maxBytes: Self.textMaxBytes))))
                fields.append(("u2v", .string(DeviceText.ascii(usage.panel2Value, maxBytes: Self.textMaxBytes))))
                if let percent = usage.panel2Percent {
                    fields.append(("u2p", .int(min(max(percent, 0), 100))))
                }
            }
            if !usage.panelDetail.isEmpty {
                fields.append(("udetail", .string(DeviceText.ascii(usage.panelDetail, maxBytes: Self.textMaxBytes))))
            }
            if !usage.panel1Detail.isEmpty {
                fields.append(("u1d", .string(DeviceText.ascii(usage.panel1Detail, maxBytes: Self.textMaxBytes))))
            }
            if !usage.panel2Detail.isEmpty {
                fields.append(("u2d", .string(DeviceText.ascii(usage.panel2Detail, maxBytes: Self.textMaxBytes))))
            }
            if !usage.panelFooterLeft.isEmpty {
                fields.append(("ufl", .string(DeviceText.ascii(usage.panelFooterLeft, maxBytes: Self.textMaxBytes))))
            }
            if !usage.panelFooterRight.isEmpty {
                fields.append(("ufr", .string(DeviceText.ascii(usage.panelFooterRight, maxBytes: Self.textMaxBytes))))
            }
            fields.append(("uready", .int(usage.ready ? 1 : 0)))
        case .caption(let app, let src, let dst, let live):
            fields.append(("app", .string(DeviceText.utf8(app, maxBytes: Self.captionAppMaxBytes))))
            fields.append(("src", .string(DeviceText.utf8Tail(src, maxBytes: Self.captionMaxBytes))))
            fields.append(("dst", .string(DeviceText.utf8Tail(dst, maxBytes: Self.captionMaxBytes))))
            fields.append(("live", .int(live ? 1 : 0)))
        case .wallpaperStart(let size, let crc):
            fields.append(("size", .int(size)))
            fields.append(("crc", .int(Int(crc))))
        case .wallpaperChunk(let offset, let base64):
            fields.append(("off", .int(offset)))
            fields.append(("d", .string(base64)))
        case .wallpaperFinish:
            fields.append(("fin", .int(1)))
        case .wallpaperClear:
            fields.append(("clear", .int(1)))
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
