import Foundation
import Testing
@testable import VibeKey

struct AgentUsageTests {
    @Test func encodesUsageForDevice() {
        let usage = DeviceUsage(
            app: "CODEX", today: "43,051,522", week: "43,051,522",
            total: "4,938,713,816", tab: 2, leftPercent: 7, reset: "4D 1H",
            plan: "plus", credits: 0, ready: true,
            fiveHourLeftPercent: 63, fiveHourReset: "2H 10M")
        let line = HostCommand.usage(usage).line
        #expect(line.contains("\"cmd\":\"usage\""))
        #expect(line.contains("\"uapp\":\"CODEX\""))
        #expect(line.contains("\"utab\":2"))
        #expect(line.contains("\"uquota\":1"))
        #expect(line.contains("\"uleft\":7"))
        #expect(line.contains("\"uplan\":\"plus\""))
        #expect(line.contains("\"u5quota\":1"))
        #expect(line.contains("\"u5left\":63"))
        #expect(line.contains("\"u5reset\":\"2H 10M\""))
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
            weeklyLeftPercent: 7, reset: "4D 1H", plan: "plus", credits: 0, ready: true,
            fiveHourLeftPercent: 63, fiveHourReset: "2H 10M",
            panel: AgentUsagePanel(
                label1: "CONTEXT", value1: "19%", percent1: 19,
                label2: "SESSIONS", value2: "136", percent2: nil,
                detail: "LAST 2H", footerLeft: "DEEPSEEK-V4.1", footerRight: "TURNS 228"))
        let device = snapshot.device(tab: 2)
        #expect(device.today == "43,051,522")
        #expect(device.total == "4,938,713,816")
        #expect(device.plan == "PLUS")
        #expect(device.leftPercent == 7)
        #expect(device.fiveHourLeftPercent == 63)
        #expect(device.fiveHourReset == "2H 10M")
        #expect(device.panel1Label == "CONTEXT")
        #expect(device.panel1Percent == 19)
        #expect(device.panel2Label == "SESSIONS")
        #expect(device.panelFooterLeft == "DEEPSEEK-V4.1")
    }

    @Test func codexPanelShowsBothResetTimes() {
        let snapshot = AgentUsageSnapshot(
            app: "CODEX", today: 43_051_522, week: 43_051_522, total: 4_938_713_816,
            weeklyLeftPercent: 7, reset: "4D 1H", plan: "plus", credits: 0, ready: true,
            fiveHourLeftPercent: 63, fiveHourReset: "2H 10M")
        let device = snapshot.device(tab: 0)
        #expect(device.panel1Label == "5H LEFT")
        #expect(device.panel1Detail == "5H RESET 2H 10M")
        #expect(device.panel2Label == "WEEK LEFT")
        #expect(device.panel2Detail == "WEEK RESET 4D 1H")
    }

    @Test func encodesGenericPanel() {
        let usage = DeviceUsage(
            app: "DSH", today: "1,000", week: "2,000", total: "3,000", tab: 0,
            leftPercent: nil, reset: "", plan: "", credits: nil, ready: true,
            panel1Label: "CONTEXT", panel1Value: "19%", panel1Percent: 19,
            panel2Label: "SESSIONS", panel2Value: "136", panel2Percent: nil,
            panelDetail: "LAST 2H", panelFooterLeft: "DEEPSEEK-V4.1", panelFooterRight: "TURNS 228")
        let line = HostCommand.usage(usage).line
        #expect(line.contains("\"u1l\":\"CONTEXT\""))
        #expect(line.contains("\"u1v\":\"19%\""))
        #expect(line.contains("\"u1p\":19"))
        #expect(line.contains("\"u2l\":\"SESSIONS\""))
        #expect(line.contains("\"udetail\":\"LAST 2H\""))
        #expect(line.contains("\"ufl\":\"DEEPSEEK-V4.1\""))
        #expect(line.contains("\"ufr\":\"TURNS 228\""))
    }

    @Test func encodesPanelRowDetails() {
        let usage = DeviceUsage(
            app: "CODEX", today: "1,000", week: "2,000", total: "3,000", tab: 0,
            leftPercent: 7, reset: "4D 1H", plan: "plus", credits: 0, ready: true,
            panel1Label: "5H LEFT", panel1Value: "63%", panel1Percent: 63,
            panel1Detail: "5H RESET 2H 10M",
            panel2Label: "WEEK LEFT", panel2Value: "7%", panel2Percent: 7,
            panel2Detail: "WEEK RESET 4D 1H",
            panelFooterLeft: "PLAN PLUS", panelFooterRight: "CREDITS 0")
        let line = HostCommand.usage(usage).line
        #expect(line.contains("\"u1d\":\"5H RESET 2H 10M\""))
        #expect(line.contains("\"u2d\":\"WEEK RESET 4D 1H\""))
    }
}
