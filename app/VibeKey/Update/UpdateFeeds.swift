import AppUpdateInstaller
import AppUpdateKit
import Foundation

/// 检查更新的数据源从哪来(调用链:AppState → UpdateFeeds.make → UpdateChecker → WindowManager.showUpdate)。
///
/// 接口地址和应用标识写在 Info.plist 的 `IBUpdateFeedURL` / `IBUpdateAppID`,编译时取自
/// `Config/App.xcconfig`(本机的 `Config/Update.local.xcconfig` 填写,不提交到仓库)。
/// - 官网版:配置为官网的更新接口;
/// - 自行编译的开源版:默认没有配置,不检查更新,设置和菜单里也不显示相关选项;想要更新提示时配置自己的接口(见 README);
/// - 调试构建:`IB_UPDATE_FEED=url` 临时换接口,`IB_UPDATE_DEMO=available|required` 用假数据弹出更新提示(不联网)。
enum UpdateFeeds {
    static func make(bundle: Bundle = .main) -> (any UpdateFeed)? {
        #if DEBUG
        if let demo = DebugHooks.updateDemoFeed { return demo }
        #endif
        guard let url = feedURL(bundle: bundle) else { return nil }
        let appID = (bundle.object(forInfoDictionaryKey: "IBUpdateAppID") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return JSONUpdateFeed(url: url, queryItems: [URLQueryItem(name: "platform", value: "macos")],
                              headers: appID.isEmpty ? [:] : ["X-App-ID": appID])
    }

    /// 应用内下载安装(Sparkle)。需要 appcast 地址和 EdDSA 公钥(Info.plist 的 SUPublicEDKey)都配置好;
    /// 缺任何一项或 Sparkle 启动失败时为 nil,更新窗口退回「在浏览器中下载」。
    @MainActor
    static func makeInstaller(bundle: Bundle = .main) -> SparkleInstaller? {
        let key = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !key.isEmpty, let appcast = httpsURL(bundle.object(forInfoDictionaryKey: "IBUpdateAppcastURL")) else { return nil }
        do {
            return try SparkleInstaller(appcastURL: appcast, hostBundle: bundle)
        } catch {
            Log.update.error("Sparkle 启动失败:\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func httpsURL(_ value: Any?) -> URL? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// 配置的接口地址;没配置或不是 HTTPS 时为 nil(不检查更新)。
    private static func feedURL(bundle: Bundle) -> URL? {
        #if DEBUG
        if let override = DebugHooks.updateFeedURL { return override }
        #endif
        return httpsURL(bundle.object(forInfoDictionaryKey: "IBUpdateFeedURL"))
    }
}
