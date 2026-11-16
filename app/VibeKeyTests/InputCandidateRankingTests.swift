import XCTest
@testable import VibeKey

nonisolated final class InputCandidateRankingTests: XCTestCase {
    private func candidate(_ role: String, _ label: String, web: Bool = true, focused: Bool = false) -> InputCandidateRanking.Candidate {
        .init(role: role, label: label, isWebContent: web, isBrowser: true, focused: focused)
    }

    func testWebCommentWinsOverSearchAndAddressBar() {
        let inputs = [candidate("AXTextField", "Address and search", web: false),
                      candidate("AXTextField", "搜索"), candidate("AXTextArea", "发表评论")]
        XCTAssertEqual(InputCandidateRanking.bestIndex(inputs), 2)
    }

    func testFocusedWebSearchWinsOverComment() {
        let inputs = [candidate("AXTextField", "搜索", focused: true), candidate("AXTextArea", "评论")]
        XCTAssertEqual(InputCandidateRanking.bestIndex(inputs), 0)
    }

    func testAmbiguousInputsAndBrowserAddressAreNotGuessed() {
        XCTAssertNil(InputCandidateRanking.bestIndex([candidate("AXTextField", "搜索", web: false)]))
        XCTAssertNil(InputCandidateRanking.bestIndex([candidate("AXTextArea", "评论"), candidate("AXTextArea", "评论")]))
        XCTAssertNil(InputCandidateRanking.bestIndex([candidate("AXTextField", "Password")]))
    }

    func testOnlyExplicitSendButtonLabelsAreSubmitted() {
        XCTAssertTrue(InputCandidateRanking.isSubmitLabel("发布评论"))
        XCTAssertTrue(InputCandidateRanking.isSubmitLabel("send"))
        XCTAssertFalse(InputCandidateRanking.isSubmitLabel("转发"))
        XCTAssertFalse(InputCandidateRanking.isSubmitLabel("评论"))
    }

    @MainActor func testWeChatVisualRecipeTargetsCurrentWindow() {
        let recipe = VisualInputFallback.weChat
        let frame = CGRect(x: 0, y: 39, width: 824, height: 1051)
        XCTAssertEqual(recipe.inputPoint(in: frame).x, 477.92, accuracy: 0.01)
        XCTAssertEqual(recipe.inputPoint(in: frame).y, 974.39, accuracy: 0.01)
        XCTAssertEqual(recipe.submitPoint(in: frame).x, 766.32, accuracy: 0.01)
        XCTAssertEqual(recipe.submitPoint(in: frame).y, 1037.45, accuracy: 0.01)
        var bound = recipe
        bound.expectedFrame = frame
        XCTAssertTrue(bound.matches(frame))
        XCTAssertFalse(bound.matches(frame.offsetBy(dx: 12, dy: 0)))
        XCTAssertEqual(VisualInputFallback.recipe(for: "com.tencent.xinWeChat"), recipe)
        XCTAssertNil(VisualInputFallback.recipe(for: "unknown.app"))
    }

    @MainActor func testFeishuVisualRecipeTargetsCurrentWindow() {
        let recipe = VisualInputFallback.feishu
        let frame = CGRect(x: 4, y: 39, width: 1456, height: 1051)
        XCTAssertEqual(recipe.inputPoint(in: frame).x, 848.48, accuracy: 0.01)
        XCTAssertEqual(recipe.inputPoint(in: frame).y, 1042.705, accuracy: 0.01)
        XCTAssertEqual(recipe.submitPoint(in: frame).x, 1358.08, accuracy: 0.01)
        XCTAssertEqual(recipe.submitPoint(in: frame).y, 1042.705, accuracy: 0.01)
        var bound = recipe
        bound.expectedFrame = frame
        XCTAssertTrue(bound.matches(frame))
        XCTAssertFalse(bound.matches(frame.offsetBy(dx: 12, dy: 0)))
        XCTAssertEqual(VisualInputFallback.recipe(for: "com.electron.lark"), recipe)
    }

    @MainActor func testCodexVisualRecipeActivatesMainComposer() {
        let recipe = VisualInputFallback.codex
        let frame = CGRect(x: 0, y: 39, width: 1800, height: 1130)
        XCTAssertEqual(recipe.inputPoint(in: frame).x, 1008, accuracy: 0.01)
        XCTAssertEqual(recipe.inputPoint(in: frame).y, 1067.3, accuracy: 0.01)
        var bound = recipe
        bound.expectedFrame = frame
        XCTAssertTrue(bound.matches(frame))
        XCTAssertFalse(bound.matches(frame.offsetBy(dx: 12, dy: 0)))
        XCTAssertEqual(VisualInputFallback.recipe(for: "com.openai.codex"), recipe)
    }
}
