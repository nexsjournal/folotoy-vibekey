import XCTest
@testable import VibeKey

nonisolated final class LanguageDetectionTests: XCTestCase {
    func testShortClipUsesPreferredLanguage() {
        XCTAssertEqual(
            SpeechLanguageDetection.resolve(
                detected: "en", probabilities: ["en": 0.95, "zh": 0.02],
                preferred: "zh", sampleCount: 16_000),
            "zh")
    }

    func testMixedChineseAndEnglishKeepsChinese() {
        XCTAssertEqual(
            SpeechLanguageDetection.resolve(
                detected: "en", probabilities: ["en": 0.55, "zh": 0.41],
                preferred: "zh", sampleCount: 16_000 * 4),
            "zh")
    }

    func testClearEnglishUsesEnglish() {
        XCTAssertEqual(
            SpeechLanguageDetection.resolve(
                detected: "en", probabilities: ["en": 0.96, "zh": 0.02],
                preferred: "zh", sampleCount: 16_000 * 4),
            "en")
    }

    func testClearJapaneseUsesJapanese() {
        XCTAssertEqual(
            SpeechLanguageDetection.resolve(
                detected: "ja", probabilities: ["ja": 0.91, "zh": 0.04],
                preferred: "zh", sampleCount: 16_000 * 4),
            "ja")
    }

    func testLowConfidenceFallsBackToPreferred() {
        XCTAssertEqual(
            SpeechLanguageDetection.resolve(
                detected: "en", probabilities: ["en": 0.32, "zh": 0.12],
                preferred: "zh", sampleCount: 16_000 * 3),
            "zh")
    }

    func testPreferredLanguageFromSystemLocale() {
        XCTAssertEqual(SpeechLanguageDetection.preferredLanguage(["zh-Hans-CN", "en-US"]), "zh")
        XCTAssertEqual(SpeechLanguageDetection.preferredLanguage(["en-US"]), "en")
        XCTAssertEqual(SpeechLanguageDetection.preferredLanguage([]), "zh")
    }
}
