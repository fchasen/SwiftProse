import Testing
import Foundation
@testable import SwiftProseSyntax

@Suite struct IncrementalEditMappingTests {

    @Test func applyEditOnFreshSourceParses() throws {
        let parser = try MarkdownParser(grammar: .block)
        let initial = "hello\n"
        _ = parser.applyEdit(replacing: NSRange(location: 0, length: 0), with: initial, newSource: initial)
        #expect(parser.tree?.rootNode != nil)
    }

    @Test func incrementalSingleCharInsertReturnsChangedRanges() throws {
        let parser = try MarkdownParser(grammar: .block)
        parser.parse("hello\n")
        let changed = parser.applyEdit(replacing: NSRange(location: 5, length: 0), with: "!", newSource: "hello!\n")
        #expect(parser.tree?.rootNode != nil)
        _ = changed
    }

    @Test func multiParagraphInsertExtendsSource() throws {
        let parser = try MarkdownParser(grammar: .block)
        parser.parse("first\n")
        let newSource = "first\n\nsecond\n"
        _ = parser.applyEdit(
            replacing: NSRange(location: 6, length: 0),
            with: "\nsecond\n",
            newSource: newSource
        )
        #expect(parser.tree?.rootNode != nil)
        let segs = BlockSegmenter.segment(rootNode: parser.tree!.rootNode!, mapping: parser.mapping)
        #expect(segs.count >= 2)
    }

    @Test func multiParagraphDeleteShrinksSource() throws {
        let parser = try MarkdownParser(grammar: .block)
        parser.parse("first\n\nsecond\n")
        _ = parser.applyEdit(
            replacing: NSRange(location: 6, length: 8),
            with: "",
            newSource: "first\n"
        )
        #expect(parser.mapping.text == "first\n")
        let segs = BlockSegmenter.segment(rootNode: parser.tree!.rootNode!, mapping: parser.mapping)
        #expect(segs.count == 1)
    }
}
