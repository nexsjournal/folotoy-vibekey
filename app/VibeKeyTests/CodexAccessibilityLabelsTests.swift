import XCTest
@testable import VibeKey

/// AX 控件分类只依赖角色和精确文案，避免把普通聊天文字当作发送或审批控件。
nonisolated final class CodexAccessibilityLabelsTests: XCTestCase {
    func testLocalizedComposerControls() {
        XCTAssertTrue(CodexAccessibilityLabels.isSend("发送"))
        XCTAssertTrue(CodexAccessibilityLabels.isSend("Send"))
        XCTAssertTrue(CodexAccessibilityLabels.isStop("停止"))
        XCTAssertTrue(CodexAccessibilityLabels.isStop("Stop"))
        XCTAssertFalse(CodexAccessibilityLabels.isSend("停止"))
    }

    func testApprovalButtonsAreRecognized() {
        XCTAssertTrue(CodexAccessibilityLabels.isApproval("允许一次"))
        XCTAssertTrue(CodexAccessibilityLabels.isApproval("始终允许"))
        XCTAssertTrue(CodexAccessibilityLabels.isApproval("拒绝"))
        XCTAssertTrue(CodexAccessibilityLabels.isApproval("Allow once"))
        XCTAssertFalse(CodexAccessibilityLabels.isApproval("发送"))
    }

    func testConversationIdentityRequiresACompleteUUID() {
        let id = "01a1ac31-36f1-7fa1-be1d-9059334e325c"
        XCTAssertTrue(CodexConversationIdentityResolver.containsThreadUUID(id))
        XCTAssertTrue(CodexConversationIdentityResolver.containsThreadUUID("codex://threads/\(id)"))
        XCTAssertFalse(CodexConversationIdentityResolver.containsThreadUUID("thread-\(id.prefix(8))"))
        XCTAssertFalse(CodexConversationIdentityResolver.containsThreadUUID("composer-send-button"))
    }

    func testWebPlaceholderIsTreatedAsEmptyOnlyWhenItMatches() {
        XCTAssertEqual(CodexInputText.effective("Ask anything", placeholder: "Ask anything"), "")
        XCTAssertEqual(CodexInputText.effective("real draft", placeholder: "Ask anything"), "real draft")
        XCTAssertEqual(CodexInputText.effective("real draft", placeholder: ""), "real draft")
    }

    func testActualEditorContentOverridesSyntheticAXValue() {
        XCTAssertEqual(CodexInputText.effective("Ask anything…", placeholder: "", characterCount: 0), "")
        XCTAssertEqual(CodexInputText.effective("Ask anything…", placeholder: "Ask anything…", characterCount: 13), "Ask anything…")
        XCTAssertEqual(CodexInputText.effective("synthetic label", placeholder: "", characterCount: 5, rangeText: "hello"), "hello")
    }

    func testProseMirrorGeneratedPlaceholderIsNotADraft() {
        // 真机结构：TextArea → Group.placeholder → Group → StaticText；AXValue 还多了一个换行。
        let empty = CodexInputContent(children: [.init(placeholder: true, children: [.init(children: [.init(text: true)])])])
        XCTAssertTrue(empty.isPlaceholderOnly)
        XCTAssertEqual(CodexInputText.effective("message hint\n", placeholder: "", characterCount: 13,
            rangeText: "message hint\n", placeholderOnly: empty.isPlaceholderOnly), "")

        let mixed = CodexInputContent(children: [empty, .init(text: true)])
        XCTAssertFalse(mixed.isPlaceholderOnly)
        XCTAssertFalse(CodexInputContent(text: true).isPlaceholderOnly)
    }
}
