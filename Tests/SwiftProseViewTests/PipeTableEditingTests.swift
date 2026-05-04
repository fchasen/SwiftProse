import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite struct PipeTableEditingTests {

    private func controllerWithTable() throws -> EditorController {
        let source = """
        | Name | Age |
        | :--- | --: |
        | Ann  | 30  |
        | Bob  | 25  |
        """ + "\n"
        let controller = try EditorController(initialMarkdown: source)
        // Move the cursor into a body cell so the table commands have an
        // anchor.
        let target = (controller.textStorage.string as NSString).range(of: "Ann")
        controller.testSelection = NSRange(location: target.location, length: 0)
        return controller
    }

    @Test func insertTableActionInsertsStubAtCursor() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        _ = controller.perform(.insertTable(rows: 2, columns: 3))
        let markdown = controller.markdown()
        #expect(markdown.contains("|"))
        #expect(markdown.contains("---"))
        // Sanity: the inserted source must re-parse as a table.
        let parsed = PipeTableModel.parse(at: 0, in: controller.textStorage)
        #expect(parsed?.columnCount == 3)
        #expect(parsed?.bodyRows.count == 2)
    }

    @Test func insertTableRowBelowExtendsTable() throws {
        let controller = try controllerWithTable()
        let before = PipeTableModel.parse(at: (controller.testSelection?.location ?? 0), in: controller.textStorage)?.bodyRows.count
        _ = controller.perform(.insertTableRowBelow)
        let after = PipeTableModel.parse(at: (controller.testSelection?.location ?? 0), in: controller.textStorage)?.bodyRows.count
        #expect(before == 2)
        #expect(after == 3)
    }

    @Test func deleteTableColumnRemovesColumn() throws {
        let controller = try controllerWithTable()
        _ = controller.perform(.deleteTableColumn)
        let parsed = PipeTableModel.parse(at: (controller.testSelection?.location ?? 0), in: controller.textStorage)
        #expect(parsed?.columnCount == 1)
    }

    @Test func setColumnAlignmentRewritesAlignmentRow() throws {
        let controller = try controllerWithTable()
        _ = controller.perform(.setTableColumnAlignment(.center))
        let parsed = PipeTableModel.parse(at: (controller.testSelection?.location ?? 0), in: controller.textStorage)
        // Cursor was on the first column ("Ann"), so column 0 → .center.
        #expect(parsed?.alignments.first == .center)
    }

    @Test func cellEditAPIRewritesSingleCell() throws {
        let controller = try controllerWithTable()
        let table = PipeTableModel.parse(at: (controller.testSelection?.location ?? 0), in: controller.textStorage)!
        _ = controller.applyTableCellEdit(
            tableRange: table.sourceRange,
            row: 0,
            column: 1,
            text: "31"
        )
        let after = PipeTableModel.parse(at: 0, in: controller.textStorage)
        #expect(after?.bodyRows.first?.last == "31")
        // Other cells untouched.
        #expect(after?.bodyRows.first?.first == "Ann")
        #expect(after?.bodyRows.last == ["Bob", "25"])
    }

    @Test func toggleExpansionPreservesSourceByteForByte() throws {
        let controller = try controllerWithTable()
        let before = controller.markdown()
        let table = PipeTableModel.parse(at: (controller.testSelection?.location ?? 0), in: controller.textStorage)!
        controller.toggleTableExpansion(tableRange: table.sourceRange)
        #expect(controller.isTableExpanded(tableRange: table.sourceRange))
        // Markdown source must round-trip identically since toggle is purely
        // a presentation flag.
        #expect(controller.markdown() == before)
        controller.toggleTableExpansion(tableRange: table.sourceRange)
        #expect(!controller.isTableExpanded(tableRange: table.sourceRange))
    }

    @Test func tableRunRangeWalksAdjacentParagraphs() throws {
        let controller = try controllerWithTable()
        let probeMid = (controller.textStorage.string as NSString).range(of: "Bob").location
        let runRange = PipeTableModel.pipeTableRunRange(at: probeMid, in: controller.textStorage)
        #expect(runRange != nil)
        // The walked run must cover at least the header + alignment + 2 rows.
        let runText = (controller.textStorage.string as NSString).substring(with: runRange!)
        #expect(runText.contains("Name"))
        #expect(runText.contains("---"))
        #expect(runText.contains("Bob"))
    }
}
