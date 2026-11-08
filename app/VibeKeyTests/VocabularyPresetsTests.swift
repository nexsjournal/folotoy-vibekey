import XCTest
@testable import VibeKey

nonisolated final class VocabularyPresetsTests: XCTestCase {
    func testMergeKeepsCustomTermsAndDeduplicates() {
        let merged = VocabularyPresets.merged(into: "我的项目\nDeepSeek = 自定义别名")
        XCTAssertTrue(merged.hasPrefix("我的项目\nDeepSeek = 自定义别名"))
        XCTAssertEqual(merged.components(separatedBy: "DeepSeek").count - 1, 1)
        XCTAssertTrue(merged.contains("Claude Code"))
        XCTAssertTrue(merged.contains("# AI 模型 / 产品"))
    }

    func testPresetCoversRequestedCategories() {
        let entries = VocabularyCorrector.parse(VocabularyPresets.recommended)
        XCTAssertGreaterThan(entries.count, 150)
        let terms = Set(entries.map(\.term))
        for term in ["DeepSeek", "Figma", "Kubernetes", "分镜", "React", "Kafka", "唐朝", "珠穆朗玛峰"] {
            XCTAssertTrue(terms.contains(term), "missing \(term)")
        }
    }

    func testPresetAliasesCorrectCommonMistakes() {
        let entries = VocabularyCorrector.parse(VocabularyPresets.recommended)
        XCTAssertEqual(VocabularyCorrector.apply("DIPSEEK", entries: entries), "DeepSeek")
        XCTAssertEqual(VocabularyCorrector.apply("kubernetes", entries: entries), "Kubernetes")
        XCTAssertEqual(VocabularyCorrector.apply("web socket", entries: entries), "WebSocket")
    }
}
