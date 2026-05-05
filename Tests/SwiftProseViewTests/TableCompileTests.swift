import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Pipe tables compile to per-cell paragraphs in storage with the full
/// structural `proseNodePath` (`[doc, blockquote*, table, table_row,
/// table_cell|table_header, paragraph]`). Cells in a row share their
/// `table_row` `NodeID`; rows under a table share its `table` `NodeID`.
@Suite struct TableCompileTests {

    private func compile(_ markdown: String) throws -> NSAttributedString {
        try MarkdownAttributedCompiler().compile(markdown, theme: .default)
    }

    private func tree(_ markdown: String) throws -> ProseDocument {
        try MarkdownAttributedCompiler().compileToTree(markdown, theme: .default)
    }

    private func cellTexts(_ tree: ProseDocument) -> [[String]] {
        guard case .structural(_, let kids) = tree.root,
              case .structural(let table, let rows) = kids.first(where: {
                  if case .structural(let n, _) = $0, n.type == "table" { return true }
                  return false
              }) ?? .leaf(ProseNode(type: "doc")),
              table.type == "table" else { return [] }
        return rows.map { row in
            guard case .structural(_, let cells) = row else { return [] }
            return cells.map { cell -> String in
                guard case .structural(_, let kids) = cell else { return "" }
                return kids.compactMap { kid -> String? in
                    if case .structural(_, let inlineKids) = kid {
                        return inlineKids.compactMap {
                            if case .inline(let t, _) = $0 { return t }
                            return nil
                        }.joined()
                    }
                    return nil
                }.joined()
            }
        }
    }

    @Test func storagePathStopsAtTableLeaf() throws {
        let storage = try compile("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        // Stage 4: storage carries one attachment + newline run with
        // `proseNodePath` ending at the `table` node (isolating). The
        // structural cells live inside `attachment.subtree`, not in
        // storage.
        var foundChain: [String]? = nil
        storage.enumerateNodePaths { _, path in
            let names = path.nodes.map(\.type)
            if names.last == "table", foundChain == nil {
                foundChain = names
            }
        }
        #expect(foundChain == ["doc", "table"])
    }

    @Test func liftedTreeShapeMatchesSchema() throws {
        let doc = try tree("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        guard let table = findTable(doc),
              case .structural(_, let rows) = table,
              let header = rows.first,
              case .structural(_, let headerCells) = header,
              let firstHeader = headerCells.first,
              case .structural(_, let headerKids) = firstHeader,
              let para = headerKids.first,
              case .structural(let paraNode, _) = para else {
            Issue.record("expected table → row → cell → paragraph structure")
            return
        }
        #expect(paraNode.type == "paragraph")
    }

    @Test func headerRowHasHeaderTrueAttr() throws {
        let doc = try tree("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        guard case .structural(_, let kids) = doc.root,
              let table = kids.first(where: { node in
                  if case .structural(let n, _) = node, n.type == "table" { return true }
                  return false
              }),
              case .structural(_, let rows) = table else {
            Issue.record("expected table in tree")
            return
        }
        guard case .structural(let firstRow, _) = rows[0] else {
            Issue.record("expected first row")
            return
        }
        #expect(firstRow.attrs["header"]?.boolValue == true)
        guard rows.count >= 2, case .structural(let secondRow, _) = rows[1] else {
            Issue.record("expected body row")
            return
        }
        #expect(secondRow.attrs["header"]?.boolValue == false)
    }

    @Test func headerCellsAreTableHeaderType() throws {
        let doc = try tree("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        guard case .structural(_, let kids) = doc.root,
              let table = kids.first(where: { node in
                  if case .structural(let n, _) = node, n.type == "table" { return true }
                  return false
              }),
              case .structural(_, let rows) = table,
              case .structural(_, let headerCells) = rows[0],
              case .structural(_, let bodyCells) = rows[1] else {
            Issue.record("expected table rows")
            return
        }
        for cell in headerCells {
            if case .structural(let n, _) = cell {
                #expect(n.type == "table_header")
            }
        }
        for cell in bodyCells {
            if case .structural(let n, _) = cell {
                #expect(n.type == "table_cell")
            }
        }
    }

    @Test func alignmentRowParsesIntoCellAttrs() throws {
        let doc = try tree("| L | C | R |\n| :--- | :---: | ---: |\n| a | b | c |\n")
        let aligns = collectAlignments(doc)
        #expect(aligns == ["left", "center", "right"])
    }

    @Test func cellInlineMarksSurvive() throws {
        let doc = try tree("| **bold** | *em* |\n| --- | --- |\n| `code` | plain |\n")
        guard let table = findTable(doc) else {
            Issue.record("no table found")
            return
        }
        // Header row, first cell — should contain inline run with strong mark.
        let headerCellMarks = collectFirstInlineMarks(in: table, row: 0, col: 0)
        #expect(headerCellMarks?.contains(type: "strong") == true)
        let bodyCodeMarks = collectFirstInlineMarks(in: table, row: 1, col: 0)
        #expect(bodyCodeMarks?.contains(type: "code") == true)
    }

    @Test func emptyCellsAreRetained() throws {
        let doc = try tree("| a |  |\n| --- | --- |\n|  | b |\n")
        let texts = cellTexts(doc)
        #expect(texts.count == 2)
        #expect(texts[0].count == 2)
        #expect(texts[0][0] == "a")
        #expect(texts[0][1] == "")
        #expect(texts[1][0] == "")
        #expect(texts[1][1] == "b")
    }

    @Test func liftedTreeRowsHaveDistinctIDs() throws {
        let doc = try tree("| h1 |\n| --- |\n| a |\n| b |\n")
        guard let table = findTable(doc),
              case .structural(_, let rows) = table else {
            Issue.record("expected table")
            return
        }
        let ids: [NodeID] = rows.compactMap {
            if case .structural(let n, _) = $0, n.type == "table_row" { return n.id }
            return nil
        }
        #expect(ids.count == rows.count)
        #expect(Set(ids).count == ids.count)
    }

    @Test func liftedTreeCellsInRowShareRow() throws {
        let doc = try tree("| h1 | h2 |\n| --- | --- |\n| a | b |\n")
        guard let table = findTable(doc),
              case .structural(_, let rows) = table else {
            Issue.record("expected table")
            return
        }
        for row in rows {
            guard case .structural(let rowNode, let cells) = row else { continue }
            #expect(rowNode.type == "table_row")
            #expect(cells.count == 2)
            for cell in cells {
                guard case .structural(let n, _) = cell else { continue }
                #expect(n.type == "table_cell" || n.type == "table_header")
            }
        }
    }

    // MARK: - helpers

    private func findTable(_ doc: ProseDocument) -> TreeNode? {
        guard case .structural(_, let kids) = doc.root else { return nil }
        return kids.first { node in
            if case .structural(let n, _) = node, n.type == "table" { return true }
            return false
        }
    }

    private func collectAlignments(_ doc: ProseDocument) -> [String] {
        guard let table = findTable(doc),
              case .structural(_, let rows) = table,
              let firstRow = rows.first,
              case .structural(_, let cells) = firstRow else { return [] }
        return cells.compactMap {
            if case .structural(let n, _) = $0 {
                return n.attrs["align"]?.stringValue ?? "<none>"
            }
            return nil
        }
    }

    private func collectFirstInlineMarks(
        in table: TreeNode,
        row rowIdx: Int,
        col colIdx: Int
    ) -> MarkSet? {
        guard case .structural(_, let rows) = table,
              rowIdx < rows.count,
              case .structural(_, let cells) = rows[rowIdx],
              colIdx < cells.count,
              case .structural(_, let cellKids) = cells[colIdx],
              let firstPara = cellKids.first,
              case .structural(_, let inlineKids) = firstPara,
              let firstInline = inlineKids.first,
              case .inline(_, let marks) = firstInline else { return nil }
        return marks
    }
}
