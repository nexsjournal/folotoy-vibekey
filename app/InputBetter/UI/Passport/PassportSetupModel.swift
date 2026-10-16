import Foundation

/// Passport 快速设置的状态与动作(引导页和设置页共用),界面只读这里的状态。
@MainActor @Observable
final class PassportSetupModel {
    enum Stage: Equatable {
        /// 还没发现设备。
        case searching
        /// 发现了运行其他固件的 Passport,需要刷 InputBetter 固件。
        case needsFirmware(DeviceLink.ForeignDevice)
        /// 正在刷固件(期间 USB 链路暂停,不能按连接状态判断)。
        case flashing
        /// 已连接 InputBetter 固件。
        case connected
    }

    let link: DeviceLink
    let flasher: FirmwareFlasher
    @ObservationIgnored private let settings: AppSettings

    /// 麦克风测试时的实时音量(0...1)。
    private(set) var micLevel: Float = 0
    private(set) var micTesting = false
    @ObservationIgnored private var micSource: PassportMicSource?
    @ObservationIgnored private var micTimeout: Task<Void, Never>?

    init(link: DeviceLink, flasher: FirmwareFlasher, settings: AppSettings) {
        self.link = link
        self.flasher = flasher
        self.settings = settings
    }

    var stage: Stage {
        if flasher.phase.isRunning { return .flashing }
        if link.connection != .disconnected { return .connected }
        if let foreign = link.foreignDevice { return .needsFirmware(foreign) }
        return .searching
    }

    /// 是否用 Passport 麦克风听写。
    var usesPassportMic: Bool {
        get { settings.micID == AppSettings.passportMicID }
        set { settings.micID = newValue ? AppSettings.passportMicID : "" }
    }

    /// 当前按键映射的动作名(说明里显示,和设置保持一致)。
    var upActionTitle: String { settings.deviceUpAction.title }
    var downActionTitle: String { settings.deviceDownAction.title }
    var downLongActionTitle: String { settings.deviceDownLongAction.title }
    /// 示意图屏幕右侧的按键提示图标(与设备空闲页一致,取自同一个映射)。
    var deviceHints: DeviceStateMapper.Hints {
        DeviceStateMapper.keyHints(state: .idle, deviceMode: .dict, handsFree: false, canTranslate: false,
                                   up: settings.deviceUpAction, down: settings.deviceDownAction)
    }

    var bluetoothAllowed: Bool {
        get { settings.deviceBluetooth }
        set { settings.deviceBluetooth = newValue }
    }

    /// 设备固件与官网最新固件不同(旧固件没有 build 字段也算不同)。还没查到官网结果时为 false。
    var firmwareUpdateAvailable: Bool {
        guard let latest = flasher.latestManifest else { return false }
        return link.firmwareBuild != latest.build
    }

    /// 已连接时能否重新刷写:需要 USB(蓝牙不能刷)和 app 内置的 esptool。
    var canReflash: Bool { link.usbPortPath != nil && flasher.esptool != nil }

    /// 进入 Passport 页面时查询官网最新固件(有缓存,不会频繁请求)。
    func checkFirmware() {
        flasher.checkLatest()
    }

    /// 刷入固件:未识别的设备用发现时的串口,已连接的设备用当前 USB 串口。
    func flashFirmware() {
        switch stage {
        case .needsFirmware(let device):
            flasher.flash(port: device.path)
        case .connected:
            if let path = link.usbPortPath { flasher.flash(port: path) }
        default:
            break
        }
    }

    /// 打开 Passport 麦克风 6 秒,显示音量,确认收音正常。
    func toggleMicTest() {
        if micTesting { stopMicTest(); return }
        let source = PassportMicSource(link: link)
        source.onSamples = { [weak self] samples in
            let level = AudioFormats.level(of: samples)
            Task { @MainActor in
                guard let self else { return }
                self.micLevel = AudioFormats.smoothLevel(self.micLevel, toward: level)
            }
        }
        do {
            try source.start()
        } catch {
            return
        }
        micSource = source
        micTesting = true
        micTimeout = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { stopMicTest() }
        }
    }

    func stopMicTest() {
        micTimeout?.cancel()
        micSource?.stop()
        micSource = nil
        micTesting = false
        micLevel = 0
    }
}
