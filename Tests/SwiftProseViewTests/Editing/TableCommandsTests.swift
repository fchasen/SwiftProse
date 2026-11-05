import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite(.serialized)
@MainActor
struct TableCommandsTests {
    @Test func deleteTableRowRemovesActiveRow() {
        let controller = EditorController(markdown: "| h |\n| --- |\n| a |\n| b |")
        let caret = TableFixture.cellStart(controller.textStorage, row: 1, column: 0)
        controller.setSelection(NSRange(location: caret, length: 0))
        controller.perform(.deleteTableRow)
        #expect(controller.markdown() == "| h |\n| --- |\n| b |")
    }

    @Test func deleteTableKeepsTheSurroundingParagraphs() {
        let controller = EditorController(markdown: "hello\n\n| h |\n| --- |\n| a |\n\nworld")
        let caret = TableFixture.cellStart(controller.textStorage, row: 1, column: 0)
        controller.setSelection(NSRange(location: caret, length: 0))
        controller.perform(.deleteTable)
        #expect(controller.markdown() == "hello\n\nworld")
        #expect(!controller.textStorage.markdownParagraphRanges().contains {
            $0.length > 0 && controller.textStorage.markdownBlock(at: $0.location)?.isTableRow == true
        })
    }

    @Test func insertTableEmitsCanonicalGFMWithACellPerColumn() {
        let controller = EditorController(markdown: "")
        controller.perform(.insertTable(rows: 2, columns: 3))
        #expect(controller.markdown() == "| | | |\n| --- | --- | --- |\n| | | |\n| | | |")
    }
}
