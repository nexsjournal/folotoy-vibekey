import Foundation
import Testing
@testable import VibeKey

struct AgentUsageTests {
    @Test func encodesUsageForDevice() {
        let usage = DeviceUsage(
            app: "CODEX", today: "43,051,522", week: "43,051,522",
            total: "4,938,713,816", tab: 2, leftPercent: 7, reset: "4D 1H",
            plan: "plus", credits: 0, ready: true)
        let line = HostCommand.usage(usage).line
        #expect(line.contains("\"cmd\":\"usage\""))
        #expect(line.contains("\"uapp\":\"CODEX\""))
        #expect(line.contains("\"utab\":2"))
        #expect(line.contains("\"uquota\":1"))
        #expect(line.contains("\"uleft\":7"))
        #expect(line.contains("\"uplan\":\"plus\""))
        #expect(line.contains("\"uready\":1"))
    }

    @Test func omitsQuotaWhenUnavailable() {
        let usage = DeviceUsage(
            app: "DSH", today: "347,148,441", week: "347,148,441",
            total: "2,345,608,689", tab: 0, leftPercent: nil, reset: "",
            plan: "deepseek", credits: nil, ready: true)
        let line = HostCommand.usage(usage).line
        #expect(!line.contains("\"uquota\""))
        #expect(!line.contains("\"uleft\""))
        #expect(!line.contains("\"ucredit\""))
        #expect(line.contains("\"uready\":1"))
    }

    @Test func snapshotFormatsDeviceNumbers() {
        let snapshot = AgentUsageSnapshot(
            app: "CODEX", today: 43_051_522, week: 43_051_522, total: 4_938_713_816,
            weeklyLeftPercent: 7, reset: "4D 1H", plan: "plus", credits: 0, ready: true)
        let device = snapshot.device(tab: 2)
        #expect(device.today == "43,051,522")
        #expect(device.total == "4,938,713,816")
        #expect(device.plan == "PLUS")
        #expect(device.leftPercent == 7)
    }
}
