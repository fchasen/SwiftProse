import Testing
import Foundation
@testable import SwiftProseTreeSitter

@Suite struct LanguageDetectionTests {
    private func detect(_ source: String, _ coverage: [String: [NSRange]]) -> String? {
        LanguageDetection.detect(in: source, candidates: Array(coverage.keys)) { coverage[$0] ?? [] }
    }

    private let body = "# Heading One\n## Heading Two\n### Heading Three\n"

    @Test func clearWinnerIsDetected() {
        let length = (body as NSString).length
        #expect(detect(body, [
            "markdown": [NSRange(location: 0, length: length / 2)],
            "swift": [NSRange(location: 0, length: 2)],
        ]) == "markdown")
    }

    @Test func unrecognisedInputIsNil() {
        #expect(detect("just a regular sentence with words", ["markdown": []]) == nil)
    }

    @Test func shortBodiesAreNeverClassified() {
        #expect(detect("# Hi", ["markdown": [NSRange(location: 0, length: 4)]]) == nil)
    }

    @Test func coverageBelowThirtyPercentIsNil() {
        let source = String(repeating: "x", count: 100)
        #expect(detect(source, ["swift": [NSRange(location: 0, length: 29)]]) == nil)
        #expect(detect(source, ["swift": [NSRange(location: 0, length: 30)]]) == "swift")
    }

    @Test func runnerUpWithinOnePointFiveIsAmbiguous() {
        let source = String(repeating: "x", count: 100)
        #expect(detect(source, [
            "javascript": [NSRange(location: 0, length: 60)],
            "swift": [NSRange(location: 0, length: 41)],
        ]) == nil)
        #expect(detect(source, [
            "javascript": [NSRange(location: 0, length: 60)],
            "swift": [NSRange(location: 0, length: 40)],
        ]) == "javascript")
    }

    @Test func tiesAreAmbiguous() {
        let source = String(repeating: "x", count: 100)
        #expect(detect(source, [
            "css": [NSRange(location: 0, length: 50)],
            "html": [NSRange(location: 50, length: 50)],
        ]) == nil)
    }

    @Test func overlappingSpansCountOnce() {
        #expect(LanguageDetection.unionLength(of: [
            NSRange(location: 0, length: 10),
            NSRange(location: 4, length: 2),
            NSRange(location: 8, length: 6),
            NSRange(location: 20, length: 5),
        ]) == 19)
    }

    @Test func highlighterWithNoLanguagesDetectsNothing() {
        let highlighter = TreeSitterCodeBlockHighlighter()
        #expect(highlighter.registeredLanguages.isEmpty)
        #expect(highlighter.detectLanguage(for: body) == nil)
    }

    @Test func sessionsNeedARegisteredLanguage() {
        let highlighter = TreeSitterCodeBlockHighlighter()
        #expect(highlighter.makeSession(language: nil, body: body) == nil)
        #expect(highlighter.makeSession(language: "swift", body: body) == nil)
    }
}

@Suite struct CodePaletteTests {
    @Test func captureNamesResolveToTheirMostSpecificTag() {
        #expect(HighlightTag(captureName: "keyword") == .keyword)
        #expect(HighlightTag(captureName: "function.method.builtin") == .function)
        #expect(HighlightTag(captureName: "string.escape") == .stringEscape)
        #expect(HighlightTag(captureName: "punctuation.bracket.round") == .punctuationBracket)
        #expect(HighlightTag(captureName: "markup.heading") == .unknown)
    }

    @Test func paletteColoursCodeTagsOnly() {
        let palette = CodePalette.default
        #expect(palette.color(for: .keyword) == palette.keyword)
        #expect(palette.color(for: .method) == palette.function)
        #expect(palette.color(for: .stringEscape) == palette.string)
        #expect(palette.color(for: .punctuationDelimiter) == palette.punctuation)
        #expect(palette.color(for: .none) == nil)
        #expect(palette.color(for: .unknown) == nil)
    }
}
