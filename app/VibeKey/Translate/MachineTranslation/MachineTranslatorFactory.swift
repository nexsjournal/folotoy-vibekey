import Foundation

/// 按服务商和凭据创建翻译器,以及配置表单里的「测试连接」。
nonisolated enum MachineTranslatorFactory {
    /// 必填字段没填全时抛 `.notConfigured`(不发出注定失败的请求,也让调用方按"整批停止"处理)。
    static func make(_ provider: TranslationProvider, credentials: MTCredentials) throws -> any MachineTranslator {
        guard credentials.isComplete(for: provider) else { throw MachineTranslationError.notConfigured }
        return switch provider {
        case .deepl: DeepLTranslator(credentials: credentials)
        case .google: GoogleTranslator(credentials: credentials)
        case .azure: AzureTranslator(credentials: credentials)
        case .volcengine: VolcengineTranslator(credentials: credentials)
        case .tencent: TencentTranslator(credentials: credentials)
        case .baidu: BaiduTranslator(credentials: credentials)
        }
    }

    /// 测试连接:把一句英文译成用户的主语言(主语言是英语时译成简体中文),返回译文,
    /// 同时验证了密钥、签名和语言代码。
    static func test(_ provider: TranslationProvider, credentials: MTCredentials) async throws -> String {
        let primary = TargetLanguage.autoPair().primary
        let (text, target): (String, TargetLanguage) = primary == .en ? ("你好，世界。", .en) : ("Hello, world.", primary)
        let result = try await make(provider, credentials: credentials.trimmed).translate([text], to: target)
        return result.first ?? ""
    }
}
