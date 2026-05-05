import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

/// Markdown ↔ NSAttributedString ↔ markdown round-trip for pipe tables.
/// Now that the compiler emits structural cells (`table → table_row →
/// table_cell|table_header → paragraph`), the serializer's structural
/// `emitTable` branch activates and per-column alignment, header
/// distinction, and inline marks all survive.
@Suite struct TableRoundTripTests {

    private func roundTrip(_ markdown: String) throws -> String {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        let attributed = compiler.compile(markdown, theme: .default)
        return serializer.serialize(attributed)
    }

    @Test func headerAndBodyDistinction() throws {
        let input = "| h1 | h2 |\n| --- | --- |\n| a | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func multipleBodyRows() throws {
        let input = "| h1 | h2 |\n| --- | --- |\n| a1 | a2 |\n| b1 | b2 |\n| c1 | c2 |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func leftAlignment() throws {
        let input = "| h1 | h2 |\n| :--- | --- |\n| a | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func rightAlignment() throws {
        let input = "| h1 | h2 |\n| --- | ---: |\n| a | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func centerAlignment() throws {
        let input = "| h1 | h2 |\n| :---: | --- |\n| a | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func mixedAlignmentsSurvive() throws {
        let input = "| L | C | R | N |\n| :--- | :---: | ---: | --- |\n| 1 | 2 | 3 | 4 |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func boldInsideCellSurvives() throws {
        let input = "| **bold** | plain |\n| --- | --- |\n| a | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func emInsideCellSurvives() throws {
        let input = "| *em* | plain |\n| --- | --- |\n| a | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func codeSpanInsideCellSurvives() throws {
        let input = "| `code` | plain |\n| --- | --- |\n| a | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func linkInsideCellSurvives() throws {
        let input = "| [docs](https://example.com) | plain |\n| --- | --- |\n| a | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func emptyCellsRoundTrip() throws {
        let input = "| a |  |\n| --- | --- |\n|  | b |\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }

    @Test func tableThenParagraphSeparation() throws {
        let input = "| h |\n| --- |\n| a |\n\nafter\n"
        let out = try roundTrip(input)
        #expect(out == input)
    }
}
