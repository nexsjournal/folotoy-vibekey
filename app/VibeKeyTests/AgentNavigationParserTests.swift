import XCTest
@testable import VibeKey

/// 通用侧栏解析的纯逻辑测试：用合成 AX 树覆盖 ZCode / Claude / WorkBuddy 的结构，
/// 以及「只有文档窗口」「侧栏在输入框右侧」这类必须拒绝的情况。
nonisolated final class AgentNavigationParserTests: XCTestCase {
    func testWorkBuddyStyleSpacesAndTimedSessions() throws {
        let root = window(
            sidebar(
                header("video-test"),
                session("创建鹈鹕骑自行车SVG动画 3天前", title: "创建鹈鹕骑自行车SVG动画"),
                header("travelapp-bp"),
                session("优化旅记时光BPPPT样式 10月27日", title: "优化旅记时光BPPPT样式")
            ),
            composer())

        let parsed = try XCTUnwrap(AgentNavigationParser.parse(root: root, windowTitle: "WorkBuddy"))
        XCTAssertEqual(parsed.projects.map(\.name), ["video-test", "travelapp-bp"])
        XCTAssertEqual(parsed.projects[0].sessions.map(\.name), ["创建鹈鹕骑自行车SVG动画"])
        XCTAssertEqual(parsed.projects[1].sessions.map(\.name), ["优化旅记时光BPPPT样式"])
        XCTAssertTrue(parsed.recent.isEmpty)
    }

    func testZCodeStyleProjectButtonAndSessionList() throws {
        let root = window(
            node("AXGroup", subrole: "AXLandmarkComplementary",
                 x: 300, width: 240, height: 500, children: [
                    node("AXGroup", x: 312, width: 217, height: 30, children: [
                        button("proj-a", x: 312, width: 120),
                    ]),
                    node("AXGroup", x: 312, width: 217, height: 80, children: [
                        node("AXList", x: 312, width: 217, height: 80, children: [
                            node("AXGroup", x: 312, width: 217, height: 32,
                                 actions: ["AXPress"], children: [text("会话一"), text("4天")]),
                        ]),
                    ]),
                 ]),
            composer())

        let parsed = try XCTUnwrap(AgentNavigationParser.parse(root: root, windowTitle: "ZCode"))
        XCTAssertEqual(parsed.projects.map(\.name), ["proj-a"])
        XCTAssertEqual(parsed.projects[0].sessions.map(\.name), ["会话一"])
    }

    func testClaudeStyleToggleAndUnreadPrefix() throws {
        let header = node("AXGroup", x: 300, width: 240, height: 40, children: [
            button("", description: "proj-b", x: 300, width: 120),
            button("Toggle sessions for proj-b", x: 420, width: 120),
        ])
        let list = node("AXList", x: 300, width: 240, height: 60, children: [
            node("AXGroup", x: 300, width: 240, height: 30, children: [
                button("Mark as unread 会话二", x: 300, width: 200, children: [text("会话二")]),
            ]),
        ])
        let root = window(
            node("AXGroup", subrole: "AXLandmarkComplementary", description: "Sidebar",
                 x: 300, width: 240, height: 500, children: [header, list]),
            composer())

        let parsed = try XCTUnwrap(AgentNavigationParser.parse(root: root, windowTitle: "Claude"))
        XCTAssertEqual(parsed.projects.map(\.name), ["proj-b"])
        XCTAssertEqual(parsed.projects[0].sessions.map(\.name), ["会话二"])
    }

    func testDocumentWindowWithoutComposerIsRejected() {
        let list = node("AXList", x: 20, width: 300, height: 400, children: [
            button("Chapter 1", x: 20, width: 200),
            button("Chapter 2", x: 20, width: 200),
        ])
        XCTAssertNil(AgentNavigationParser.parse(root: window(list), windowTitle: "Notes"))
    }

    func testSidebarWithoutComposerIsRejected() {
        let root = window(sidebar(
            header("proj"),
            session("Chat 3天前", title: "Chat")))
        XCTAssertNil(AgentNavigationParser.parse(root: root, windowTitle: "App"))
    }

    func testNavigationRightOfComposerIsRejected() {
        let rightList = node("AXList", x: 900, width: 300, height: 400, children: [
            button("Recent file 1", x: 900, width: 200),
            button("Recent file 2", x: 900, width: 200),
        ])
        let root = window(rightList, composer(x: 100, width: 600))
        XCTAssertNil(AgentNavigationParser.parse(root: root, windowTitle: "Editor"))
    }

    func testChromeButtonsAreNotSessions() throws {
        let root = window(
            sidebar(
                header("proj"),
                button("搜索", x: 320, width: 80),
                button("设置", x: 320, width: 80),
                session("真实会话 2小时前", title: "真实会话")),
            composer())

        let parsed = try XCTUnwrap(AgentNavigationParser.parse(root: root, windowTitle: "App"))
        XCTAssertEqual(parsed.projects.flatMap { $0.sessions.map(\.name) }, ["真实会话"])
    }

    func testHeadingMarksCurrentSession() throws {
        let root = window(
            sidebar(
                header("proj"),
                session("会话一 1天前", title: "会话一"),
                session("会话二 2天前", title: "会话二")),
            node("AXHeading", x: 800, width: 300, height: 30, children: [text("会话二")]),
            composer())

        let parsed = try XCTUnwrap(AgentNavigationParser.parse(root: root, windowTitle: "App"))
        let sessions = parsed.projects[0].sessions
        XCTAssertEqual(sessions.map(\.isCurrent), [false, true])
        XCTAssertTrue(parsed.projects[0].isCurrent)
    }

    func testCleanNameStripsLabelsAndTimes() {
        XCTAssertEqual(AgentNavigationParser.cleanName("Mark as unread 项目审查"), "项目审查")
        XCTAssertEqual(AgentNavigationParser.cleanName("Toggle sessions for proj"), "proj")
        XCTAssertEqual(AgentNavigationParser.cleanName("创建动画 3天前"), "创建动画")
        XCTAssertEqual(AgentNavigationParser.cleanName("A task Oct 27"), "A task Oct 27")
    }

    func testLogoHeaderMatchingWindowTitleIsDropped() throws {
        let root = window(
            sidebar(
                node("AXGroup", x: 320, width: 80, height: 22, children: [
                    button("AppName", x: 320, width: 80),
                ]),
                header("proj"),
                session("会话 1天前", title: "会话")),
            composer())

        let parsed = try XCTUnwrap(AgentNavigationParser.parse(root: root, windowTitle: "AppName"))
        XCTAssertEqual(parsed.projects.map(\.name), ["proj"])
    }

    // MARK: - 合成 AX 树

    private func window(_ children: AXSnapshotNode...) -> AXSnapshotNode {
        node("AXWindow", x: 0, y: 0, width: 1_400, height: 900, children: children)
    }

    private func composer(x: Double = 800, width: Double = 600) -> AXSnapshotNode {
        node("AXTextArea", x: x, y: 400, width: width, height: 60)
    }

    private func sidebar(_ children: AXSnapshotNode...) -> AXSnapshotNode {
        node("AXGroup", x: 300, y: 0, width: 240, height: 860, children: children)
    }

    /// 单行纯文字分组头（WorkBuddy 的空间名）。
    private func header(_ name: String) -> AXSnapshotNode {
        node("AXGroup", x: 312, width: 217, height: 34, children: [
            node("AXGroup", x: 348, width: 120, height: 22, children: [text(name)]),
        ])
    }

    /// 带相对时间的会话行（WorkBuddy 把时间拼在按钮标题里）。
    private func session(_ title: String, title sessionTitle: String) -> AXSnapshotNode {
        let time = title.split(separator: " ").last.map(String.init) ?? ""
        return node("AXGroup", x: 312, width: 217, height: 32, children: [
            button(title, x: 312, width: 217, children: [text(sessionTitle), text(time)]),
        ])
    }

    private func text(_ value: String) -> AXSnapshotNode {
        node("AXStaticText", x: 320, width: 200, height: 20, value: value)
    }

    private func button(_ title: String, description: String = "",
                        x: Double, width: Double, children: [AXSnapshotNode] = []) -> AXSnapshotNode {
        node("AXButton", title: title, description: description, x: x, width: width,
             height: 24, actions: ["AXPress"], children: children)
    }

    private func node(_ role: String, subrole: String = "", title: String = "",
                      description: String = "", x: Double, y: Double = 0,
                      width: Double, height: Double, value: String = "",
                      actions: Set<String> = [], children: [AXSnapshotNode] = []) -> AXSnapshotNode {
        AXSnapshotNode(
            role: role, subrole: subrole, title: title, description: description,
            value: value, actions: actions,
            rect: .init(x: x, y: y, width: width, height: height), children: children)
    }
}
