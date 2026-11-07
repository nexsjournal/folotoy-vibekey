import AppKit
import XCTest
@testable import VibeKey

/// XCTest 宿主不能启动设备链路或触发用户权限。
nonisolated final class TestHostIsolationTests: XCTestCase {
    @MainActor func testHostDoesNotStartApplicationServices() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["IB_TEST_MODE"], "1")
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertNil(delegate.state)
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.folobutton.dev")
        XCTAssertTrue(CredentialStore.defaultURL.path.contains("/FoloButtonDev/"))
    }
}
