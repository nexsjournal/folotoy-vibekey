import Foundation

/// 把设备上行字节流拆成文本行和二进制帧(docs/protocol.md「二进制帧」)。
///
/// - 文本按 `\n` 组行(去掉行尾 `\r`),超长行整行丢弃到下一个换行。
/// - 帧头 `FF FE type seq len_lo len_hi`,负载 1...1024 字节。`0xFF`/`0xFE` 不会出现在 UTF-8 文本里,
///   所以帧可以夹在一行中间;帧结束后继续拼接被打断的那一行。
/// - 第二字节不是 `0xFE` 时只丢掉 `0xFF`,该字节按文本重新处理;长度非法时丢掉 `FF FE`,
///   其余 4 个头字节重新送入状态机(重新同步)。
///
/// 值类型,不加锁:同一实例只能在一个串行上下文里使用。
nonisolated struct StreamDecoder: Sendable {
    enum Item: Equatable, Sendable {
        case line(String)
        case frame(type: UInt8, seq: UInt8, payload: Data)
    }

    static let sync0: UInt8 = 0xFF
    static let sync1: UInt8 = 0xFE
    static let headerSize = 6
    static let maxPayload = 1024
    /// 协议规定单行 JSON 最长 511 字节;USB 上 ESP-IDF 日志前缀可能和 JSON 落在同一行,所以放宽一些。
    static let defaultMaxLineBytes = 1024

    private enum Mode: Sendable {
        case text
        case header
        case payload
    }

    private let maxLineBytes: Int
    private var mode = Mode.text
    private var line: [UInt8] = []
    private var discardingLine = false
    private var header: [UInt8] = []
    private var payload: [UInt8] = []
    private var expected = 0

    init(maxLineBytes: Int = StreamDecoder.defaultMaxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    mutating func reset() {
        mode = .text
        line.removeAll(keepingCapacity: true)
        discardingLine = false
        header.removeAll(keepingCapacity: true)
        payload.removeAll(keepingCapacity: true)
        expected = 0
    }

    mutating func feed(_ data: Data) -> [Item] {
        var items: [Item] = []
        for byte in data {
            consume(byte, into: &items)
        }
        return items
    }

    mutating func feed(_ bytes: [UInt8]) -> [Item] {
        var items: [Item] = []
        for byte in bytes {
            consume(byte, into: &items)
        }
        return items
    }

    private mutating func consume(_ byte: UInt8, into items: inout [Item]) {
        switch mode {
        case .text:
            if byte == Self.sync0 {
                mode = .header
                header.removeAll(keepingCapacity: true)
                header.append(byte)
            } else {
                feedText(byte, into: &items)
            }

        case .header:
            if header.count == 1, byte != Self.sync1 {
                // 不是帧头:丢掉 0xFF,当前字节按文本(或新的 0xFF)重新处理。
                mode = .text
                consume(byte, into: &items)
                return
            }
            header.append(byte)
            guard header.count == Self.headerSize else { return }
            let length = Int(header[4]) | (Int(header[5]) << 8)
            if length == 0 || length > Self.maxPayload {
                // 长度非法:丢掉 FF FE,剩下的头字节重新送入状态机。
                let rest = Array(header[2...])
                mode = .text
                header.removeAll(keepingCapacity: true)
                for b in rest {
                    consume(b, into: &items)
                }
            } else {
                expected = length
                payload.removeAll(keepingCapacity: true)
                payload.reserveCapacity(length)
                mode = .payload
            }

        case .payload:
            payload.append(byte)
            if payload.count == expected {
                items.append(.frame(type: header[2], seq: header[3], payload: Data(payload)))
                mode = .text
            }
        }
    }

    private mutating func feedText(_ byte: UInt8, into items: inout [Item]) {
        if byte == 0x0A {
            if !discardingLine {
                if line.last == 0x0D {
                    line.removeLast()
                }
                if !line.isEmpty {
                    items.append(.line(String(decoding: line, as: UTF8.self)))
                }
            }
            line.removeAll(keepingCapacity: true)
            discardingLine = false
            return
        }
        if discardingLine {
            return
        }
        if line.count >= maxLineBytes {
            line.removeAll(keepingCapacity: true)
            discardingLine = true
            return
        }
        line.append(byte)
    }
}

/// 编码一个二进制帧(测试与诊断用;协议 v1 里 Mac 不下发二进制帧)。
nonisolated enum DeviceFrame {
    static let typeADPCM: UInt8 = 0x02

    /// 负载为空或超过 1024 字节时返回 nil。
    static func encode(type: UInt8, seq: UInt8, payload: Data) -> Data? {
        guard !payload.isEmpty, payload.count <= StreamDecoder.maxPayload else { return nil }
        var data = Data(capacity: StreamDecoder.headerSize + payload.count)
        data.append(contentsOf: [
            StreamDecoder.sync0, StreamDecoder.sync1, type, seq,
            UInt8(payload.count & 0xFF), UInt8(payload.count >> 8),
        ])
        data.append(payload)
        return data
    }
}
