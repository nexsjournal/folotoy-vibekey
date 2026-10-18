import AppKit
import Foundation
import Observation
import Sparkle

/// 用 Sparkle 2 下载并安装更新,进度交给 app 自己的界面显示。
///
/// 为什么用 Sparkle:它是 macOS 官网分发 app 的业内标准更新框架——下载后用 EdDSA 签名校验更新包
/// (公钥在 Info.plist 的 `SUPublicEDKey`,私钥只在发布者本机),并核对新版本的代码签名与当前一致,
/// 再由独立的安装进程替换 app、自动重启。
///
/// 分工:「有没有新版本、要不要强制」由 AppUpdateKit 的 `UpdateChecker` 决定并提示用户;用户点「下载并安装」后
/// 才调用 `install()`。所以这里关掉了 Sparkle 自己的定时检查和询问,`SPUUserDriver` 只用来接收进度:
/// 发现更新直接安装、下载 / 解压 / 安装各阶段写进 `phase`,界面据此显示进度条。
///
/// appcast 地址由调用方传入(不写在 Info.plist 的 `SUFeedURL` 里,便于按构建配置)。只在主线程使用。
@MainActor @Observable
public final class SparkleInstaller {
    /// 安装进度。
    public enum Phase: Equatable, Sendable {
        case idle
        /// 正在向 appcast 确认更新包。
        case checking
        /// 正在下载;expected 为 nil 表示服务器没给出大小。
        case downloading(received: UInt64, expected: UInt64?)
        /// 正在解压 / 校验(0...1)。
        case extracting(Double)
        /// 正在安装,app 即将退出并自动重新打开。
        case installing
        /// app 没能退出(例如用户在退出确认里取消了),等待重试。
        case waitingToQuit
        /// 失败(界面显示原因,并提供「在浏览器中下载」兜底)。
        case failed(String)

        /// 是否在进行中(按钮应禁用)。
        public var isBusy: Bool {
            switch self {
            case .checking, .downloading, .extracting, .installing: true
            case .idle, .waitingToQuit, .failed: false
            }
        }
    }

    public private(set) var phase: Phase = .idle
    /// Sparkle 请求把更新界面放到前面时调用(例如用户再次点检查更新)。
    @ObservationIgnored public var onFocusRequest: (() -> Void)?

    @ObservationIgnored private var updater: SPUUpdater!
    @ObservationIgnored private let driver = Driver()
    @ObservationIgnored private let feed: FeedDelegate
    @ObservationIgnored private var cancelDownload: (() -> Void)?
    @ObservationIgnored private var retryQuit: (() -> Void)?

    /// 创建并启动 Sparkle。宿主 app 的 Info.plist 必须有 `SUPublicEDKey`,否则 Sparkle 拒绝启动(抛错),
    /// 调用方应退回「在浏览器中下载」。
    public init(appcastURL: URL, hostBundle: Bundle = .main) throws {
        feed = FeedDelegate(url: appcastURL)
        updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: driver, delegate: feed)
        driver.owner = self
        try updater.start()
        // 检查时机由 UpdateChecker 决定,Sparkle 不自己定时检查,也不在第二次启动时询问用户。
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
    }

    /// 下载并安装 appcast 里的最新版本。进行中再次调用只把界面放到前面。
    public func install() {
        if phase.isBusy { onFocusRequest?(); return }
        if phase == .waitingToQuit, let retryQuit { phase = .installing; retryQuit(); return }
        phase = .checking
        updater.checkForUpdates()
    }

    /// 取消下载(下载阶段之后无法取消)。
    public func cancel() {
        cancelDownload?()
        cancelDownload = nil
        phase = .idle
    }

    /// 清除失败状态(用户关闭窗口时)。
    public func reset() {
        if !phase.isBusy { phase = .idle }
    }

    // MARK: - 来自 Driver 的事件(主线程)

    fileprivate func handle(_ event: Driver.Event) {
        switch event {
        case .checking:
            phase = .checking
        case .downloadStarted(let cancel):
            cancelDownload = cancel
            phase = .downloading(received: 0, expected: nil)
        case .expectedLength(let length):
            if case .downloading(let received, _) = phase { phase = .downloading(received: received, expected: length) }
        case .received(let length):
            if case .downloading(let received, let expected) = phase { phase = .downloading(received: received + length, expected: expected) }
        case .extracting(let progress):
            cancelDownload = nil
            phase = .extracting(progress)
        case .installing:
            phase = .installing
        case .waitingToQuit(let retry):
            retryQuit = retry
            phase = .waitingToQuit
        case .failed(let message):
            cancelDownload = nil
            phase = .failed(message)
        case .dismissed:
            cancelDownload = nil
            if phase.isBusy { phase = .idle }
        case .focus:
            onFocusRequest?()
        }
    }
}

/// appcast 地址(代替 Info.plist 的 SUFeedURL)。
private final class FeedDelegate: NSObject, SPUUpdaterDelegate {
    let url: URL
    init(url: URL) { self.url = url }
    func feedURLString(for updater: SPUUpdater) -> String? { url.absoluteString }
}

/// Sparkle 的用户界面回调:不显示 Sparkle 自带的窗口,把事件转给 SparkleInstaller。
/// Sparkle 把这个协议标成主线程(UI actor)调用。
@MainActor
private final class Driver: NSObject, SPUUserDriver {
    enum Event {
        case checking
        case downloadStarted(() -> Void)
        case expectedLength(UInt64)
        case received(UInt64)
        case extracting(Double)
        case installing
        case waitingToQuit(() -> Void)
        case failed(String)
        case dismissed
        case focus
    }

    weak var owner: SparkleInstaller?
    private func send(_ event: Event) { owner?.handle(event) }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 定时检查由 UpdateChecker 负责;不发送系统信息。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { send(.checking) }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // 用户已经在 app 的更新窗口里选择了安装;这里直接继续(包括之前下载到一半 / 已下载好的情况)。
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // UpdateChecker 认为有新版本、appcast 却没有:通常是 appcast 还没发布或缺少签名。
        send(.failed(error.localizedDescription))
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        send(.failed(error.localizedDescription))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { send(.downloadStarted(cancellation)) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { send(.expectedLength(expectedContentLength)) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { send(.received(length)) }
    func showDownloadDidStartExtractingUpdate() { send(.extracting(0)) }
    func showExtractionReceivedProgress(_ progress: Double) { send(.extracting(progress)) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // 用户点的就是「下载并安装」,校验通过后直接安装并重启,不再二次确认。
        send(.installing)
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        // app 没退出(例如退出前的确认被取消):等用户处理后重试。
        if applicationTerminated { send(.installing) } else { send(.waitingToQuit(retryTerminatingApplication)) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdateInFocus() { send(.focus) }
    func dismissUpdateInstallation() { send(.dismissed) }
}
