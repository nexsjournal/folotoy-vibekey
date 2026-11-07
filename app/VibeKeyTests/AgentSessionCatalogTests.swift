import XCTest
@testable import VibeKey

/// 纯数据 / 字符串测试；真实 AX 树只在运行中的 Codex / DSH 上验证，不放进单元测试宿主。
nonisolated final class AgentSessionCatalogTests: XCTestCase {
    func testWindowTitleMatching() {
        XCTAssertTrue(AgentSessionNameMatcher.matches(windowTitle: "处理绿色图裁剪布局", sessionName: "处理绿色图裁剪布局"))
        XCTAssertTrue(AgentSessionNameMatcher.matches(
            windowTitle: "多角色产品体验评测 — DeepSeek Harness", sessionName: "多角色产品体验评测"))
        XCTAssertTrue(AgentSessionNameMatcher.matches(windowTitle: "Chat 1 - Extra", sessionName: "Chat 1"))
        XCTAssertTrue(AgentSessionNameMatcher.matches(windowTitle: "A", sessionName: "A"))
        XCTAssertFalse(AgentSessionNameMatcher.matches(windowTitle: "A - extra", sessionName: "A"))
        XCTAssertFalse(AgentSessionNameMatcher.matches(windowTitle: "unrelated", sessionName: "A"))
        XCTAssertFalse(AgentSessionNameMatcher.matches(windowTitle: "", sessionName: "Chat"))
    }

    func testDisplayNamesMarkCurrentItems() {
        let session = AgentSession(name: "Chat", index: 0, isCurrent: true)
        XCTAssertEqual(session.displayName, "* Chat")
        let project = AgentProject(name: "project", index: 0, sessions: [session], isCurrent: true)
        XCTAssertEqual(project.displayName, "* project")
        XCTAssertEqual(AgentProjectChoice.project(project).displayName, "* project")
        XCTAssertEqual(AgentProjectChoice.switchApp.displayName, "SWITCH APP")
        XCTAssertEqual(AgentProjectChoice.recent.displayName, "RECENT")
    }

    func testAgentShortNames() {
        XCTAssertEqual(AgentSessionApp(pid: 1, bundleID: "com.openai.codex", name: "ChatGPT").shortName, "CODEX")
        XCTAssertEqual(AgentSessionApp(pid: 1, bundleID: "com.openai.codex", name: "ChatGPT").targetName, "Codex")
        XCTAssertEqual(AgentSessionApp(pid: 1, bundleID: "ai.deepseek.dsh.desktop.next", name: "DSH NEXT").shortName, "DSH")
        XCTAssertEqual(AgentSessionApp(pid: 1, bundleID: "ai.deepseek.dsh.desktop.next", name: "DSH NEXT").targetName, "DeepSeek")
    }
}
