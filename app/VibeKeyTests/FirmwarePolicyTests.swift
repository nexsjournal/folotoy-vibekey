import XCTest
@testable import VibeKey

/// 开发分支不能下载或刷入上游官网固件,即使调用方绕过设置页面也不能写入。
nonisolated final class FirmwarePolicyTests: XCTestCase {
    @MainActor func testOfficialFlashingIsDisabled() {
        let link = DeviceLink()
        let flasher = FirmwareFlasher(link: link, downloader: FirmwareDownloader(manifestURL: FirmwareDownloader.officialManifestURL))
        XCTAssertFalse(FirmwareFlasher.onlineFirmwareAllowed)
        flasher.checkLatest(force: true)
        XCTAssertEqual(flasher.latest, .unknown)
        flasher.flash(port: "/dev/nonexistent-test")
        guard case .failed = flasher.phase else { return XCTFail("官网刷写必须被拒绝") }
        XCTAssertEqual(link.connection, .disconnected)
    }
}
