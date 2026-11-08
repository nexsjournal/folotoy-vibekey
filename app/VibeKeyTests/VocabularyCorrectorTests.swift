import XCTest
@testable import VibeKey

nonisolated final class VocabularyCorrectorTests: XCTestCase {
    private let entries = VocabularyCorrector.parse([
        "DeepSeek = DIPSEEK, deep seek, 迪普希克",
        "Claude Code",
        "SwiftUI",
        "Go",
    ])

    func testParsesPreferredTermAndAliases() {
        XCTAssertEqual(entries.first?.term, "DeepSeek")
        XCTAssertEqual(entries.first?.aliases, ["DIPSEEK", "deep seek", "迪普希克"])
        XCTAssertEqual(VocabularyCorrector.promptTerms(entries), ["DeepSeek", "Claude Code", "SwiftUI", "Go"])
    }

    func testCorrectsCommonMishearing() {
        XCTAssertEqual(
            VocabularyCorrector.apply("我觉得 DIPSEEK 的 API 很好用", entries: entries),
            "我觉得 DeepSeek 的 API 很好用")
    }

    func testJoinsSpacedPhrase() {
        XCTAssertEqual(
            VocabularyCorrector.apply("open deep seek docs", entries: entries),
            "open DeepSeek docs")
        XCTAssertEqual(
            VocabularyCorrector.apply("use swift ui here", entries: entries),
            "use SwiftUI here")
    }

    func testCorrectsChineseAliasAndKeepsPunctuation() {
        XCTAssertEqual(
            VocabularyCorrector.apply("迪普希克，你好", entries: entries),
            "DeepSeek，你好")
    }

    func testDoesNotRewriteOrdinaryWords() {
        XCTAssertEqual(
            VocabularyCorrector.apply("the clause is fine", entries: entries),
            "the clause is fine")
        XCTAssertEqual(
            VocabularyCorrector.apply("go to the next page", entries: entries),
            "go to the next page")
    }

    func testPromptDescriptionIncludesAliases() {
        XCTAssertEqual(
            VocabularyCorrector.promptDescriptions(entries).first,
            "DeepSeek (often misheard as DIPSEEK, deep seek, 迪普希克)")
    }
}
