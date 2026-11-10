import XCTest
@testable import VibeKey

nonisolated final class VocabularyPresetsTests: XCTestCase {
    func testMergeKeepsCustomTermsAndDeduplicates() {
        let merged = VocabularyPresets.merged(into: "我的项目\nDeepSeek = 自定义别名")
        XCTAssertTrue(merged.hasPrefix("我的项目\nDeepSeek = 自定义别名"))
        XCTAssertEqual(merged.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("DeepSeek =") }.count, 1)
        XCTAssertTrue(merged.contains("Claude Code"))
        XCTAssertTrue(merged.contains("# AI 模型 / 产品"))
    }

    func testPresetCoversRequestedCategories() {
        let entries = VocabularyCorrector.parse(VocabularyPresets.recommended)
        XCTAssertGreaterThan(entries.count, 150)
        let terms = Set(entries.map(\.term))
        for term in ["DeepSeek", "Figma", "Kubernetes", "分镜", "React", "Kafka",
                     "唐朝", "珠穆朗玛峰", "36氪", "机器之心", "TechCrunch", "小红书"] {
            XCTAssertTrue(terms.contains(term), "missing \(term)")
        }
    }

    func testPresetAliasesCorrectCommonMistakes() {
        let entries = VocabularyCorrector.parse(VocabularyPresets.recommended)
        XCTAssertEqual(VocabularyCorrector.apply("DIPSEEK", entries: entries), "DeepSeek")
        XCTAssertEqual(VocabularyCorrector.apply("kubernetes", entries: entries), "Kubernetes")
        XCTAssertEqual(VocabularyCorrector.apply("web socket", entries: entries), "WebSocket")
        XCTAssertEqual(VocabularyCorrector.apply("现在吸屏的时候", entries: entries), "现在熄屏的时候")
        XCTAssertEqual(VocabularyCorrector.apply("把 usage 和 token 显示出来", entries: entries), "把 Usage 和 Token 显示出来")
    }

    func testHighFrequencyDeviceTermsReachWhisperPrompt() {
        let entries = VocabularyCorrector.parse(VocabularyPresets.recommended)
        let prompt = VocabularyCorrector.promptTerms(entries)
        XCTAssertEqual(Array(prompt.prefix(12)), [
            "VibeKey", "FoloVibe Key", "FoloToy", "Passport", "Codex",
            "DeepSeek Harness", "WorkBuddy", "ZCode", "Usage", "Token",
            "熄屏", "点亮屏幕"
        ])
    }
}
