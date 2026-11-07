import Foundation

/// 一种翻译方式的批量限制和请求频率(在线服务按各家文档;系统翻译 / AI 有各自的经验值)。
nonisolated struct BatchLimits: Equatable, Sendable {
    /// 一次请求最多几句。
    var maxItems: Int
    /// 一次请求的总长度上限(字符数,或 UTF-8 字节数)。
    var maxLength: Int
    /// 长度按 UTF-8 字节计算(百度)。
    var countsUTF8Bytes = false
    /// 多句拼成一个请求时,每两句之间分隔符的长度(百度用换行拼接 = 1;其余服务按数组发送 = 0)。
    /// 分隔符也算进服务端的长度上限,切块时要一起计入。
    var separatorLength = 0
    /// 同时进行的请求数上限。
    var maxConcurrent: Int
    /// 两次请求开始之间至少间隔多少秒(QPS 限制)。
    var minInterval: TimeInterval

    /// 一句的长度。按 Unicode 标量(码点)而不是 Swift 的字符(字素簇)计数:各家服务按码点或 UTF-16 计费和限长,
    /// 一个 emoji / 组合字符序列是一个 Character 却是多个码点,按 Character 数会低估,导致请求超限。
    func length(of text: String) -> Int {
        countsUTF8Bytes ? text.utf8.count : text.unicodeScalars.count
    }

    /// 系统翻译:本机执行,不限频率;一次处理一批同语言对的句子。
    static let system = BatchLimits(maxItems: 20, maxLength: 20_000, maxConcurrent: 1, minInterval: 0)
    /// AI:一次请求放十几句(带编号),同时最多 2 个请求。
    static let llm = BatchLimits(maxItems: 12, maxLength: 4_000, maxConcurrent: 2, minInterval: 0)
}
