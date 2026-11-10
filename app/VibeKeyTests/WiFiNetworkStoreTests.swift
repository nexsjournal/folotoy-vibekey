import Foundation
import XCTest
@testable import VibeKey

nonisolated final class WiFiNetworkStoreTests: XCTestCase {
    func testRoundTripAndLegacyMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("credentials.json")
        let credentials = CredentialStore(url: url)
        let firstKey = Data(repeating: 0x11, count: 32)
        let secondKey = Data(repeating: 0x22, count: 32)
        let networks = [
            PairedWiFiNetwork(ssid: "Home", host: "fb-home", key: firstKey),
            PairedWiFiNetwork(ssid: "Office", host: "fb-office", key: secondKey),
        ]
        PairedWiFiNetworkStore.save(networks, activeHost: "fb-office", to: credentials)
        XCTAssertEqual(PairedWiFiNetworkStore.load(from: credentials), networks)
        XCTAssertEqual(PairedWiFiNetworkStore.activeHost(from: credentials, networks: networks), "fb-office")

        let legacy = CredentialStore(url: directory.appendingPathComponent("legacy.json"))
        legacy.set("fb-legacy", for: PairedWiFiNetworkStore.legacyHostKey)
        legacy.set(secondKey.map { String(format: "%02x", $0) }.joined(), for: PairedWiFiNetworkStore.legacyKeyKey)
        let migrated = PairedWiFiNetworkStore.load(from: legacy)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].host, "fb-legacy")
        XCTAssertEqual(migrated[0].key, secondKey)
    }

    func testControlAndProvisioningCommandsDoNotContainSecretsUnlessAdding() throws {
        let select = try JSONSerialization.jsonObject(
            with: WiFiNetworkControl(operation: .select, ssid: "Office").encoded()) as? [String: Any]
        XCTAssertEqual(select?["op"] as? String, "select")
        XCTAssertEqual(select?["ssid"] as? String, "Office")
        XCTAssertNil(select?["password"])
        XCTAssertNil(select?["psk"])

        let bluetooth = try JSONSerialization.jsonObject(
            with: WiFiNetworkControl(operation: .bluetooth, ssid: "").encoded()) as? [String: Any]
        XCTAssertEqual(bluetooth?["op"] as? String, "ble")
        XCTAssertNil(bluetooth?["ssid"])

        let key = Data(repeating: 7, count: 32)
        let add = try JSONSerialization.jsonObject(
            with: WiFiProvisioning(ssid: "Home", password: "12345678", host: "fb-home", key: key).encoded()
        ) as? [String: Any]
        XCTAssertEqual(add?["op"] as? String, "add")
        XCTAssertEqual(add?["psk"] as? String, String(repeating: "07", count: 32))
    }
}
