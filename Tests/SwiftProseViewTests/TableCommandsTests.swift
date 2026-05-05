import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView

/// Stage 7 — table-structure commands operate on `attachment.subtree`
/// via `Step.setTableSubtree`. Each test loads a markdown table, runs
/// a command, and asserts the resulting subtree shape on the
/// attachment.
@Suite struct TableCommandsTests {

    private func makeController(_ markdown: String) throws -> EditorController {
        try EditorController(initialMarkdown: markdown)
    }

    private func tableAttachment(in storage: NSAttributedString) -> ProseNodeAttachment? {
        var found: ProseNodeAttachment?
        storage.enumerateNodePaths { runRange, path in
            guard found == nil,
                  let leaf = path.leaf, leaf.type == "table" else { return }
            found = storage.attribute(
                NSAttributedString.Key("NSAttachment"),
                at: runRange.location,
                effectiveRange: nil
            ) as? ProseNodeAttachment
        }
        return found
    }

    private func rowCount(_ attachment: ProseNodeAttachment) -> Int {
        if case .structural(_, let rows) = attachment.subtree { return rows.count }
        return 0
    }

    private func columnCount(_ attachment: ProseNodeAttachment) -> Int {
        guard case .structural(_, let rows) = attachment.subtree,
              let first = rows.first,
              case .structural(_, let cells) = first else { return 0 }
        return cells.count
    }

    @Test func insertTableRowBelowAddsBodyRow() throws {
        let controller = try makeController("| h |\n| --- |\n| a |\n")
        let attachment = try #require(tableAttachment(in: controller.textStorage))
        let priorRows = rowCount(attachment)
        let cmd = InsertTableRowBelowCommand()
        let env = StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
        let tx = try #require(cmd.transaction(
            storage: controller.textStorage,
            selection: NSRange(location: 0, length: 0),
            env: env
        ))
        _ = controller.apply(tx)
        #expect(rowCount(attachment) == priorRows + 1)
    }

    @Test func insertTableRowAboveInsertsAfterHeader() throws {
        let controller = try makeController("| h |\n| --- |\n| a |\n")
        let attachment = try #require(tableAttachment(in: controller.textStorage))
        let cmd = InsertTableRowAboveCommand()
        let env = StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
        let tx = try #require(cmd.transaction(
            storage: controller.textStorage,
            selection: NSRange(location: 0, length: 0),
            env: env
        ))
        _ = controller.apply(tx)
        #expect(rowCount(attachment) == 3)
    }

    @Test func deleteTableRowRemovesActiveRow() throws {
        let controller = try makeController("| h |\n| --- |\n| a |\n| b |\n")
        let attachment = try #require(tableAttachment(in: controller.textStorage))
        let cmd = DeleteTableRowCommand()
        let env = StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
        // Active cell is unset → defaults to last row.
        let tx = try #require(cmd.transaction(
            storage: controller.textStorage,
            selection: NSRange(location: 0, length: 0),
            env: env
        ))
        _ = controller.apply(tx)
        #expect(rowCount(attachment) == 2)
    }

    @Test func insertTableColumnAfterAddsColumnToEveryRow() throws {
        let controller = try makeController("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        let attachment = try #require(tableAttachment(in: controller.textStorage))
        let cmd = InsertTableColumnAfterCommand()
        let env = StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
        let tx = try #require(cmd.transaction(
            storage: controller.textStorage,
            selection: NSRange(location: 0, length: 0),
            env: env
        ))
        _ = controller.apply(tx)
        #expect(columnCount(attachment) == 3)
    }

    @Test func deleteTableColumnRemovesFromEveryRow() throws {
        let controller = try makeController("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        let attachment = try #require(tableAttachment(in: controller.textStorage))
        let cmd = DeleteTableColumnCommand()
        let env = StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
        let tx = try #require(cmd.transaction(
            storage: controller.textStorage,
            selection: NSRange(location: 0, length: 0),
            env: env
        ))
        _ = controller.apply(tx)
        #expect(columnCount(attachment) == 1)
    }

    @Test func setTableColumnAlignmentUpdatesEveryCellInColumn() throws {
        let controller = try makeController("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        let attachment = try #require(tableAttachment(in: controller.textStorage))
        let cmd = SetTableColumnAlignmentCommand(alignment: .center)
        let env = StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
        let tx = try #require(cmd.transaction(
            storage: controller.textStorage,
            selection: NSRange(location: 0, length: 0),
            env: env
        ))
        _ = controller.apply(tx)
        guard case .structural(_, let rows) = attachment.subtree else {
            Issue.record("expected table subtree")
            return
        }
        for row in rows {
            guard case .structural(_, let cells) = row,
                  let firstCell = cells.first,
                  case .structural(let cellNode, _) = firstCell else { continue }
            #expect(cellNode.attrs["align"]?.stringValue == "center")
        }
    }

    @Test func deleteTableReplacesAttachmentWithEmptyParagraph() throws {
        let controller = try makeController("hello\n\n| h |\n| --- |\n| a |\n\nworld\n")
        // Place selection inside the table attachment range.
        var tableLoc: NSRange?
        controller.textStorage.enumerateNodePaths { runRange, path in
            if path.leaf?.type == "table", tableLoc == nil { tableLoc = runRange }
        }
        let location = try #require(tableLoc)
        let cmd = DeleteTableCommand()
        let env = StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
        let tx = try #require(cmd.transaction(
            storage: controller.textStorage,
            selection: location,
            env: env
        ))
        _ = controller.apply(tx)
        // After delete, no `table` leaf should remain.
        var sawTable = false
        controller.textStorage.enumerateNodePaths { _, path in
            if path.leaf?.type == "table" { sawTable = true }
        }
        #expect(!sawTable)
    }

    @Test func insertTableEmitsAttachmentAtCursor() throws {
        let controller = try makeController("paragraph\n")
        let cmd = InsertTableCommand(rows: 2, columns: 2)
        let env = StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
        // First sanity-check: compile the command's markdown directly to
        // confirm tree-sitter parses it as a table.
        let directCompile = controller.compiler.compile(
            "\n| Column 1 | Column 2 |\n| --- | --- |\n|   |   |\n|   |   |\n",
            theme: controller.theme
        )
        var sawTableInDirect = false
        directCompile.enumerateNodePaths { _, path in
            if path.leaf?.type == "table" { sawTableInDirect = true }
        }
        #expect(sawTableInDirect, "direct compile should produce a table attachment")

        let tx = try #require(cmd.transaction(
            storage: controller.textStorage,
            selection: NSRange(location: controller.textStorage.length, length: 0),
            env: env
        ))
        _ = controller.apply(tx)
        // Debug: dump storage state.
        var pathDump: [String] = []
        controller.textStorage.enumerateNodePaths { runRange, path in
            pathDump.append("[\(runRange.location), \(runRange.length)]: \(path.nodes.map(\.type).joined(separator: "/"))")
        }
        #expect(tableAttachment(in: controller.textStorage) != nil, "paths: \(pathDump.joined(separator: "; "))")
    }
}
