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

    /// 保留 UTF-8(中文字幕用),从头截断到 `maxBytes` 且不切断字符;应用名等短文本使用。
    static func utf8(_ text: String, maxBytes: Int) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for raw in text.unicodeScalars {
            let scalar = clean(raw)
            let n = String(scalar).utf8.count
            guard bytes + n <= maxBytes else { break }
            out.append(scalar)
            bytes += n
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 保留 UTF-8 并截取末尾 `maxBytes` 字节(字幕只关心最新内容),不切断字符。
    static func utf8Tail(_ text: String, maxBytes: Int) -> String {
        var scalars: [Unicode.Scalar] = []
        var bytes = 0
        for raw in text.unicodeScalars.reversed() {
            let scalar = clean(raw)
            let n = String(scalar).utf8.count
            guard bytes + n <= maxBytes else { break }
            scalars.insert(scalar, at: 0)
            bytes += n
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 字幕里保留换行(设备按行显示),其它控制字符变空格。
    private static func clean(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar == "\n" || scalar == "\r" { return "\n" }
        if scalar.value < 0x20 || scalar.value == 0x7F { return " " }
        return scalar
    }
}
