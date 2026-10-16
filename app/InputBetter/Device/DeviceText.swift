import Foundation

/// 设备屏幕只显示 ASCII:先尽量转写为拉丁字母(中文转拼音、去掉变音符号),
/// 再把剩下的非 ASCII 折叠成 `?`,控制字符变空格,最后截断到 `maxBytes` 字节并去掉首尾空白。
nonisolated enum DeviceText {
    static func ascii(_ text: String, maxBytes: Int = HostCommand.textMaxBytes) -> String {
        var source = text
        if !source.unicodeScalars.allSatisfy({ $0.isASCII }) {
            source = source.applyingTransform(.toLatin, reverse: false) ?? source
            source = source.applyingTransform(.stripCombiningMarks, reverse: false) ?? source
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(source.utf8.count, maxBytes))
        for scalar in source.unicodeScalars {
            guard bytes.count < maxBytes else { break }
            let v = scalar.value
            if v >= 0x20, v < 0x7F {
                bytes.append(UInt8(v))
            } else if v < 0x20 || v == 0x7F || scalar.properties.isWhitespace {
                bytes.append(0x20)
            } else {
                bytes.append(UInt8(ascii: "?"))
            }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
