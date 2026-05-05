import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Stage 6 — `Step.replaceCellInline` mutates the table attachment's
/// subtree in place; storage character range stays unchanged. Inverse
/// step restores prior runs, so undo round-trips cell content.
@Suite struct TableCellEditTests {

    private func tableAttachment(
        in storage: NSAttributedString
    ) -> (range: NSRange, attachment: ProseNodeAttachment, id: NodeID)? {
        var found: (NSRange, ProseNodeAttachment, NodeID)?
        storage.enumerateNodePaths { runRange, path in
            guard found == nil,
                  let leaf = path.leaf, leaf.type == "table" else { return }
            let raw = storage.attribute(
                NSAttributedString.Key("NSAttachment"),
                at: runRange.location,
                effectiveRange: nil
            )
            if let att = raw as? ProseNodeAttachment {
                found = (runRange, att, leaf.id)
            }
        }
        return found
    }

    private func makeController(_ markdown: String) throws -> EditorController {
        try EditorController(initialMarkdown: markdown)
    }

    private func makeEnv(_ controller: EditorController) -> StepEnvironment {
        StepEnvironment(
            compiler: controller.compiler,
            serializer: controller.serializer,
            theme: controller.theme
        )
    }

    @Test func replaceCellInlineUpdatesAttachmentSubtree() throws {
        let controller = try makeController("| h |\n| --- |\n| a |\n")
        guard let (_, attachment, id) = tableAttachment(in: controller.textStorage) else {
            Issue.record("no table attachment found")
            return
        }
        let runs: [TreeNode] = [.inline(text: "x", marks: MarkSet())]
        let step = Step.replaceCellInline(tableID: id, row: 1, column: 0, runs: runs)
        _ = step.apply(to: controller.textStorage, env: makeEnv(controller))

        guard case .structural(_, let rows) = attachment.subtree,
              rows.count >= 2,
              case .structural(_, let bodyCells) = rows[1],
              let firstCell = bodyCells.first,
              case .structural(_, let cellKids) = firstCell,
              let para = cellKids.first,
              case .structural(_, let inlines) = para,
              let firstInline = inlines.first,
              case .inline(let text, _) = firstInline else {
            Issue.record("unexpected subtree shape after edit")
            return
        }
        #expect(text == "x")
    }

    @Test func replaceCellInlineInverseRestoresPriorRuns() throws {
        let controller = try makeController("| h |\n| --- |\n| a |\n")
        guard let (_, attachment, id) = tableAttachment(in: controller.textStorage) else {
            Issue.record("no table attachment found")
            return
        }
        let priorSubtree = attachment.subtree
        let runs: [TreeNode] = [.inline(text: "x", marks: MarkSet())]
        let step = Step.replaceCellInline(tableID: id, row: 1, column: 0, runs: runs)
        let applied = step.apply(to: controller.textStorage, env: makeEnv(controller))
        _ = applied.inverse.apply(to: controller.textStorage, env: makeEnv(controller))

        // After inverse, attachment.subtree should match the prior shape
        // (cell text is "a" again).
        guard case .structural(_, let rows) = attachment.subtree,
              rows.count >= 2,
              case .structural(_, let bodyCells) = rows[1],
              let firstCell = bodyCells.first,
              case .structural(_, let cellKids) = firstCell,
              let para = cellKids.first,
              case .structural(_, let inlines) = para,
              let firstInline = inlines.first,
              case .inline(let text, _) = firstInline else {
            Issue.record("unexpected subtree after inverse")
            return
        }
        #expect(text == "a")
        // Sanity: the table id is preserved across mutations.
        if case .structural(let table, _) = attachment.subtree {
            #expect(table.id == id)
        }
        _ = priorSubtree
    }

    @Test func replaceCellInlineLeavesStorageRangeUnchanged() throws {
        let controller = try makeController("| h |\n| --- |\n| a |\n")
        let priorLength = controller.textStorage.length
        guard let (_, _, id) = tableAttachment(in: controller.textStorage) else {
            Issue.record("no table attachment found")
            return
        }
        let runs: [TreeNode] = [.inline(text: "completely new", marks: MarkSet())]
        let step = Step.replaceCellInline(tableID: id, row: 1, column: 0, runs: runs)
        _ = step.apply(to: controller.textStorage, env: makeEnv(controller))
        #expect(controller.textStorage.length == priorLength)
    }

    @Test func setTableSubtreeReplacesEntireSubtree() throws {
        let controller = try makeController("| h |\n| --- |\n| a |\n")
        guard let (_, attachment, id) = tableAttachment(in: controller.textStorage) else {
            Issue.record("no table attachment found")
            return
        }
        let original = attachment.subtree
        let replacement: TreeNode
        if case .structural(let table, _) = original {
            replacement = .structural(
                table,
                [
                    .structural(
                        ProseNode(type: "table_row", attrs: ["header": .bool(true)]),
                        [.structural(
                            ProseNode(type: "table_header", attrs: ["align": .null]),
                            [.structural(ProseNode(type: "paragraph"), [.inline(text: "X", marks: MarkSet())])]
                        )]
                    )
                ]
            )
        } else {
            replacement = original
        }
        let step = Step.setTableSubtree(tableID: id, subtree: replacement)
        let applied = step.apply(to: controller.textStorage, env: makeEnv(controller))

        if case .structural(_, let rows) = attachment.subtree {
            #expect(rows.count == 1)
        }

        // Inverse restores original.
        _ = applied.inverse.apply(to: controller.textStorage, env: makeEnv(controller))
        if case .structural(_, let rows) = attachment.subtree {
            #expect(rows.count == 2)  // header + body row
        }
    }

    @Test func cellEditPreservesMarks() throws {
        let controller = try makeController("| h |\n| --- |\n| a |\n")
        guard let (_, attachment, id) = tableAttachment(in: controller.textStorage) else {
            Issue.record("no table attachment found")
            return
        }
        let strongMark = MarkSet().adding(ProseMark(type: "strong"), in: .defaultMarkdown)
        let runs: [TreeNode] = [
            .inline(text: "bold", marks: strongMark),
            .inline(text: " plain", marks: MarkSet())
        ]
        let step = Step.replaceCellInline(tableID: id, row: 1, column: 0, runs: runs)
        _ = step.apply(to: controller.textStorage, env: makeEnv(controller))

        guard case .structural(_, let rows) = attachment.subtree,
              case .structural(_, let bodyCells) = rows[1],
              case .structural(_, let cellKids) = bodyCells[0],
              case .structural(_, let inlines) = cellKids[0],
              inlines.count >= 2 else {
            Issue.record("expected two inline runs with marks")
            return
        }
        if case .inline(_, let firstMarks) = inlines[0] {
            #expect(firstMarks.contains(type: "strong"))
        }
        if case .inline(_, let secondMarks) = inlines[1] {
            #expect(!secondMarks.contains(type: "strong"))
        }
    }
}
