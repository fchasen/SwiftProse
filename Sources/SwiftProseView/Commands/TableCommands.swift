import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Locate the table-attachment under the cursor (or, lacking a cell-
/// active hint, the first attachment in the document). Returns the
/// table's `NodeID`, the attachment, the storage range it occupies, and
/// the active cell if the bound view tracked focus.
struct TableLocator {
    let id: NodeID
    let attachment: ProseNodeAttachment
    let range: NSRange
    let activeCell: (row: Int, column: Int)?
    let table: ProseNode
    let rows: [TreeNode]
    let columnCount: Int

    static func locate(
        in storage: NSAttributedString,
        selection: NSRange
    ) -> TableLocator? {
        var found: (NodeID, ProseNodeAttachment, NSRange)? = nil
        var foundIntersecting: (NodeID, ProseNodeAttachment, NSRange)? = nil
        storage.enumerateNodePaths { runRange, path in
            guard let leaf = path.leaf, leaf.type == "table" else { return }
            let raw = storage.attribute(
                NSAttributedString.Key("NSAttachment"),
                at: runRange.location,
                effectiveRange: nil
            )
            guard let att = raw as? ProseNodeAttachment else { return }
            if found == nil { found = (leaf.id, att, runRange) }
            let runEnd = runRange.location + runRange.length
            let selEnd = selection.location + selection.length
            if selection.location >= runRange.location, selEnd <= runEnd {
                foundIntersecting = (leaf.id, att, runRange)
            }
        }
        let pick = foundIntersecting ?? found
        guard let (id, attachment, range) = pick,
              case .structural(let table, let rows) = attachment.subtree else {
            return nil
        }
        let cols = rows.map { row -> Int in
            if case .structural(_, let cells) = row { return cells.count }
            return 0
        }.max() ?? 0
        return TableLocator(
            id: id,
            attachment: attachment,
            range: range,
            activeCell: attachment.boundView?.activeCell,
            table: table,
            rows: rows,
            columnCount: cols
        )
    }
}

private func makeEmptyCellNode(
    isHeader: Bool,
    align: ProseAttrValue
) -> TreeNode {
    let cell = ProseNode(
        type: isHeader ? "table_header" : "table_cell",
        attrs: [
            "align": align,
            "colspan": .int(1),
            "rowspan": .int(1),
            "colwidth": .null
        ]
    )
    let para = TreeNode.structural(ProseNode(type: "paragraph"), [])
    return .structural(cell, [para])
}

private func columnAlignments(_ rows: [TreeNode]) -> [ProseAttrValue] {
    guard let first = rows.first,
          case .structural(_, let cells) = first else { return [] }
    return cells.compactMap {
        if case .structural(let n, _) = $0 {
            return n.attrs["align"] ?? .null
        }
        return nil
    }
}

private func makeRow(
    isHeader: Bool,
    columnCount: Int,
    alignments: [ProseAttrValue]
) -> TreeNode {
    let row = ProseNode(type: "table_row", attrs: ["header": .bool(isHeader)])
    var cells: [TreeNode] = []
    for col in 0..<columnCount {
        let align = col < alignments.count ? alignments[col] : .null
        cells.append(makeEmptyCellNode(isHeader: isHeader, align: align))
    }
    return .structural(row, cells)
}

public struct InsertTableRowAboveCommand: Command {
    public let id = "insertTableRowAbove"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        TableLocator.locate(in: storage, selection: selection) != nil
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let loc = TableLocator.locate(in: storage, selection: selection) else { return nil }
        let target = loc.activeCell?.row ?? 1
        let isHeader = (target == 0)
        let aligns = columnAlignments(loc.rows)
        let newRow = makeRow(isHeader: isHeader, columnCount: loc.columnCount, alignments: aligns)
        var rows = loc.rows
        let safe = max(0, min(target, rows.count))
        rows.insert(newRow, at: safe)
        let subtree = TreeNode.structural(loc.table, rows)
        return Transaction(steps: [.setTableSubtree(tableID: loc.id, subtree: subtree)])
    }
}

public struct InsertTableRowBelowCommand: Command {
    public let id = "insertTableRowBelow"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        TableLocator.locate(in: storage, selection: selection) != nil
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let loc = TableLocator.locate(in: storage, selection: selection) else { return nil }
        let target = loc.activeCell?.row ?? loc.rows.count - 1
        let aligns = columnAlignments(loc.rows)
        let newRow = makeRow(isHeader: false, columnCount: loc.columnCount, alignments: aligns)
        var rows = loc.rows
        let safe = max(0, min(target + 1, rows.count))
        rows.insert(newRow, at: safe)
        let subtree = TreeNode.structural(loc.table, rows)
        return Transaction(steps: [.setTableSubtree(tableID: loc.id, subtree: subtree)])
    }
}

public struct DeleteTableRowCommand: Command {
    public let id = "deleteTableRow"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        guard let loc = TableLocator.locate(in: storage, selection: selection) else { return false }
        // Need at least one row to remain; can't delete the only header.
        return loc.rows.count > 1
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let loc = TableLocator.locate(in: storage, selection: selection),
              loc.rows.count > 1 else { return nil }
        let target = loc.activeCell?.row ?? loc.rows.count - 1
        var rows = loc.rows
        let safe = max(0, min(target, rows.count - 1))
        rows.remove(at: safe)
        let subtree = TreeNode.structural(loc.table, rows)
        return Transaction(steps: [.setTableSubtree(tableID: loc.id, subtree: subtree)])
    }
}

public struct InsertTableColumnBeforeCommand: Command {
    public let id = "insertTableColumnBefore"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        TableLocator.locate(in: storage, selection: selection) != nil
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let loc = TableLocator.locate(in: storage, selection: selection) else { return nil }
        let target = loc.activeCell?.column ?? 0
        return spliceColumn(loc, at: target)
    }
}

public struct InsertTableColumnAfterCommand: Command {
    public let id = "insertTableColumnAfter"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        TableLocator.locate(in: storage, selection: selection) != nil
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let loc = TableLocator.locate(in: storage, selection: selection) else { return nil }
        let target = (loc.activeCell?.column ?? loc.columnCount - 1) + 1
        return spliceColumn(loc, at: target)
    }
}

private func spliceColumn(_ loc: TableLocator, at target: Int) -> Transaction? {
    let aligns = columnAlignments(loc.rows)
    let safe = max(0, min(target, loc.columnCount))
    var newRows: [TreeNode] = []
    for row in loc.rows {
        guard case .structural(let rowNode, var cells) = row else { continue }
        let isHeader = rowNode.attrs["header"]?.boolValue ?? false
        let align = safe < aligns.count ? aligns[safe] : .null
        let cell = makeEmptyCellNode(isHeader: isHeader, align: align)
        cells.insert(cell, at: max(0, min(safe, cells.count)))
        newRows.append(.structural(rowNode, cells))
    }
    let subtree = TreeNode.structural(loc.table, newRows)
    return Transaction(steps: [.setTableSubtree(tableID: loc.id, subtree: subtree)])
}

public struct DeleteTableColumnCommand: Command {
    public let id = "deleteTableColumn"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        guard let loc = TableLocator.locate(in: storage, selection: selection) else { return false }
        return loc.columnCount > 1
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let loc = TableLocator.locate(in: storage, selection: selection),
              loc.columnCount > 1 else { return nil }
        let target = loc.activeCell?.column ?? loc.columnCount - 1
        let safe = max(0, min(target, loc.columnCount - 1))
        var newRows: [TreeNode] = []
        for row in loc.rows {
            guard case .structural(let rowNode, var cells) = row else { continue }
            if safe < cells.count { cells.remove(at: safe) }
            newRows.append(.structural(rowNode, cells))
        }
        let subtree = TreeNode.structural(loc.table, newRows)
        return Transaction(steps: [.setTableSubtree(tableID: loc.id, subtree: subtree)])
    }
}

public struct SetTableColumnAlignmentCommand: Command {
    public let alignment: PipeTableAlignment
    public var id: String { "setTableColumnAlignment" }
    public init(alignment: PipeTableAlignment) { self.alignment = alignment }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        TableLocator.locate(in: storage, selection: selection) != nil
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let loc = TableLocator.locate(in: storage, selection: selection) else { return nil }
        let target = loc.activeCell?.column ?? 0
        let alignAttr: ProseAttrValue
        switch alignment {
        case .none: alignAttr = .null
        case .left: alignAttr = .string("left")
        case .right: alignAttr = .string("right")
        case .center: alignAttr = .string("center")
        }
        var newRows: [TreeNode] = []
        for row in loc.rows {
            guard case .structural(let rowNode, var cells) = row else { continue }
            if target < cells.count,
               case .structural(let cellNode, let kids) = cells[target] {
                var attrs = cellNode.attrs
                attrs["align"] = alignAttr
                let newCell = ProseNode(id: cellNode.id, type: cellNode.type, attrs: attrs)
                cells[target] = .structural(newCell, kids)
            }
            newRows.append(.structural(rowNode, cells))
        }
        let subtree = TreeNode.structural(loc.table, newRows)
        return Transaction(steps: [.setTableSubtree(tableID: loc.id, subtree: subtree)])
    }
}

public struct DeleteTableCommand: Command {
    public let id = "deleteTable"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        TableLocator.locate(in: storage, selection: selection) != nil
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let loc = TableLocator.locate(in: storage, selection: selection) else { return nil }
        // Replace the attachment+newline with an empty paragraph so the
        // line layout stays sane.
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: env.theme.bodyFont,
            .foregroundColor: env.theme.foregroundColor
        ]
        let replacement = NSMutableAttributedString(
            string: "\n",
            attributes: baseAttrs
        )
        replacement.setBlockSpec(
            .paragraph,
            in: NSRange(location: 0, length: replacement.length)
        )
        return Transaction(steps: [.replaceText(range: loc.range, with: replacement)])
    }
}

public struct InsertTableCommand: Command {
    public let rows: Int
    public let columns: Int
    public var id: String { "insertTable" }
    public init(rows: Int = 2, columns: Int = 3) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
    }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        // Always allowed at top-level paragraphs; allow inside paragraphs
        // (the insert lives between siblings) — disallow when cursor is
        // already inside a table attachment.
        if let _ = TableLocator.locate(in: storage, selection: selection) {
            // If cursor is inside the attachment range, refuse.
            // (Locator.range == attachment range; locate already prefers
            // the intersecting one.)
            return false
        }
        return true
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        var lines: [String] = []
        // Tree-sitter-markdown requires non-empty header cells; use
        // placeholder labels rather than blanks so the table parses.
        let headerCells = (1...columns).map { " Column \($0) " }
        lines.append("|" + headerCells.joined(separator: "|") + "|")
        let alignment = "|" + Array(repeating: " --- |", count: columns).joined()
        lines.append(alignment)
        for _ in 0..<rows {
            let body = "|" + Array(repeating: "   |", count: columns).joined()
            lines.append(body)
        }
        var markdown = lines.joined(separator: "\n") + "\n"
        // Pipe-table block grammar requires the table to sit at column
        // 0 of a fresh paragraph. Ensure two newlines (i.e. a blank
        // line) precede the table source — needed when the cursor is
        // mid-paragraph or right after one.
        let ns = storage.string as NSString
        let last: unichar = selection.location > 0 ? ns.character(at: selection.location - 1) : 0
        let secondLast: unichar = selection.location > 1 ? ns.character(at: selection.location - 2) : 0
        let nl = unichar(("\n" as Character).asciiValue ?? 10)
        if selection.location == 0 {
            // start of document — no prefix needed
        } else if last != nl {
            markdown = "\n\n" + markdown
        } else if secondLast != nl {
            markdown = "\n" + markdown
        }
        let compiled = env.compiler.compile(markdown, theme: env.theme)
        return Transaction(steps: [.replaceText(range: selection, with: compiled)])
    }
}

/// Single-cell text edit hook. Builds a `Step.replaceCellInline` that
/// targets the located table by id.
public func makeSetTableCellTextTransaction(
    storage: NSTextStorage,
    tableRange: NSRange,
    row: Int,
    column: Int,
    text: String,
    env: StepEnvironment
) -> Transaction? {
    guard let loc = TableLocator.locate(in: storage, selection: tableRange) else { return nil }
    let runs: [TreeNode] = text.isEmpty
        ? []
        : [.inline(text: text, marks: MarkSet())]
    let step = Step.replaceCellInline(
        tableID: loc.id,
        row: row,
        column: column,
        runs: runs
    )
    return Transaction(steps: [step])
}
