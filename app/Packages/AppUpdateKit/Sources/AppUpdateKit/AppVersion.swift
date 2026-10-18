import Foundation

/// 点分数字版本号(1–4 段,如 `1.2`、`0.1.4`),可选数字构建号。
///
/// 比较规则:缺少的段按 0 处理(`1.2` == `1.2.0`);版本相同时构建号大的更新(任一方没有构建号则视为相同)。
/// 与后台(0os Console `shared/versions.ts`)的规则一致,两边对同一组输入得出相同结论。
public struct AppVersion: Sendable, Comparable, CustomStringConvertible {
    public let parts: [Int]
    public let build: Int?

    /// 解析版本号;格式不对(含字母、空段、超过 4 段)时返回 nil。
    public init?(_ version: String, build: String? = nil) {
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard (1...5).contains(piece.count), piece.allSatisfy(\.isASCII), piece.allSatisfy(\.isNumber),
                  let value = Int(piece) else { return nil }
            parts.append(value)
        }
        self.parts = parts
        if let build, !build.isEmpty {
            guard build.count <= 9, build.allSatisfy(\.isASCII), build.allSatisfy(\.isNumber), let value = Int(build) else { return nil }
            self.build = value
        } else {
            self.build = nil
        }
    }

    /// 当前 app 的版本(Info.plist 的 CFBundleShortVersionString / CFBundleVersion)。
    public static func current(of bundle: Bundle = .main) -> AppVersion? {
        AppVersion(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                   build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// 只比较版本号段,不看构建号(强制更新的「版本 ≤ X」用这个)。
    public func compareVersion(_ other: AppVersion) -> ComparisonResult {
        for i in 0..<max(parts.count, other.parts.count) {
            let a = i < parts.count ? parts[i] : 0, b = i < other.parts.count ? other.parts[i] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        switch lhs.compareVersion(rhs) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            guard let a = lhs.build, let b = rhs.build else { return false }
            return a < b
        }
    }

    /// 相等:末尾的 0 段不影响(`1.2` == `1.2.0`);任一方没有构建号时不比较构建号。
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    /// 只显示版本号(如 `0.1.4`),构建号另外显示。
    public var description: String { parts.map(String.init).joined(separator: ".") }
}
