import CryptoKit
import Foundation

/// 请求签名用到的哈希与编码工具(火山引擎、腾讯云签名和百度的 MD5 签名 / 表单编码共用,只实现一次)。
nonisolated enum SigningCrypto {
    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    static func hmacSHA256(key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// MD5 只用于百度翻译接口规定的签名格式(不是安全用途)。
    static func md5Hex(_ text: String) -> String {
        hex(Data(Insecure.MD5.hash(data: Data(text.utf8))))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 3986 非保留字符:只有 ASCII 字母数字和 `-._~`。
    /// 按规范显式列出,不用 `CharacterSet.alphanumerics`(它包含汉字等所有 Unicode 字母,语义不符)。
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// RFC 3986 百分号编码:非保留字符原样保留,其余(包括空格、`+`、非 ASCII)按 UTF-8 编成 `%XX`(大写十六进制)。
    /// 用于火山引擎签名的规范查询串和百度的表单请求体。
    static func rfc3986Encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// UTC 时间格式化(签名里的日期 / 时间戳)。
    static func utc(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
