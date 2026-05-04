import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Build a Step that swaps the source range of a pipe table for the
/// re-rendered source of `model`. Compiles the new source through the same
/// `MarkdownAttributedCompiler` instance the controller uses so the
/// resulting attributed string carries the proper `.pipeTable` BlockSpec
/// runs and per-line attribute flags.
private func replaceTable(
    storage: NSAttributedString,
    tableRange: NSRange,
    with model: PipeTableModel,
    env: StepEnvironment
) -> Step {
    let newSource = model.renderSource()
    let compiled = env.compiler.compile(newSource, theme: env.theme)
    return .replaceText(range: tableRange, with: compiled)
}

/// Resolve the cursor's enclosing table run plus a parsed model. Returns
/// nil when the cursor isn't inside a `.pipeTable` paragraph or when the
/// source doesn't parse cleanly (the fallback `appendOpaqueBlock` path
/// might leave us with characters that don't form a valid GFM table).
private func tableContext(
    storage: NSAttributedString,
    selection: NSRange
) -> (range: NSRange, model: PipeTableModel)? {
    guard let model = PipeTableModel.parse(at: selection.location, in: storage) else { return nil }
    return (model.sourceRange, model)
}

/// Map the cursor offset to the enclosing table line, then to (row, column)
/// indices in the model. Header → `row == -1`; alignment → `row == -2`
/// (the commands skip the alignment row and act on the nearest body row
/// instead). Returns nil for cursors outside a table.
private func tableCursor(
    storage: NSAttributedString,
    selection: NSRange,
    model: PipeTableModel
) -> (lineIndex: Int, row: Int, column: Int)? {
    guard let lineIdx = model.lineRanges.firstIndex(where: {
        $0.location <= selection.location && selection.location < $0.location + max(1, $0.length)
    }) else { return nil }
    // Approximate the column from the line's leading run of `|`-separated
    // segments. Splitting the line text at `|` matches what the model used
    // to enumerate cells, so the indices line up.
    let lineRange = model.lineRanges[lineIdx]
    let lineText = (storage.string as NSString).substring(with: lineRange)
    let cursorInLine = max(0, selection.location - lineRange.location)
    var col = 0
    var i = 0
    var sawLeadingPipe = false
    for ch in lineText {
        if i >= cursorInLine { break }
        if ch == "|" {
            if !sawLeadingPipe {
                sawLeadingPipe = true
            } else {
                col += 1
            }
        }
        i += 1
    }
    let row: Int
    switch model.lineKinds[lineIdx] {
    case .header:
        row = -1
    case .alignment:
        row = -2
    case .body(let r):
        row = r
    }
    return (lineIdx, row, col)
}

// MARK: - Insert table

public struct InsertTableCommand: Command {
    public let rows: Int
    public let columns: Int
    public var id: String { "insertTable" }
    public init(rows: Int = 2, columns: Int = 3) {
        self.rows = rows
        self.columns = columns
    }

    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }

    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let model = PipeTableModel.stub(columnCount: columns, bodyRowCount: rows)
        let source = model.renderSource()
        let compiled = env.compiler.compile(source, theme: env.theme)
        // Insert at the start of the cursor's line so the table doesn't
        // collide with a half-finished paragraph.
        let ns = storage.string as NSString
        let lineRange = ns.length == 0 ? NSRange(location: 0, length: 0)
            : ns.paragraphRange(for: NSRange(location: max(0, min(selection.location, ns.length - 1)), length: 0))
        // Pad the table with a leading newline if we're inserting mid-document
        // and the previous line has content; pad with a trailing newline if
        // there's text after.
        let prefix = (lineRange.location > 0 && (storage.string as NSString).character(at: lineRange.location - 1) != 0x0A) ? "\n" : ""
        let suffix = "\n"
        let payload = NSMutableAttributedString(string: prefix)
        payload.append(compiled)
        payload.append(NSAttributedString(string: suffix))
        return Transaction(
            steps: [.replaceText(range: NSRange(location: lineRange.location, length: 0), with: payload)],
            label: "Insert Table"
        )
    }
}

// MARK: - Row / column structural mutations

private struct TableMutationCommand: Command {
    let id: String
    let label: String
    let mutate: (PipeTableModel, _ row: Int, _ column: Int) -> PipeTableModel?

    func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        tableContext(storage: storage, selection: selection) != nil
    }

    func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let ctx = tableContext(storage: storage, selection: selection),
              let cursor = tableCursor(storage: storage, selection: selection, model: ctx.model) else { return nil }
        guard let mutated = mutate(ctx.model, cursor.row, cursor.column) else { return nil }
        return Transaction(
            steps: [replaceTable(storage: storage, tableRange: ctx.range, with: mutated, env: env)],
            label: label
        )
    }
}

public struct InsertTableRowAboveCommand: Command {
    public let id = "insertTableRowAbove"
    public init() {}
    private let inner = TableMutationCommand(id: "insertTableRowAbove", label: "Insert Row Above") { model, row, _ in
        // Header → insert as the new first body row. Alignment → no-op.
        let target = max(-1, row) // -1 maps to "before body row 0"
        return model.insertingRow(after: target - 1)
    }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        inner.canExecute(storage: storage, selection: selection)
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        inner.transaction(storage: storage, selection: selection, env: env)
    }
}

public struct InsertTableRowBelowCommand: Command {
    public let id = "insertTableRowBelow"
    public init() {}
    private let inner = TableMutationCommand(id: "insertTableRowBelow", label: "Insert Row Below") { model, row, _ in
        let target = max(-1, row)
        return model.insertingRow(after: target)
    }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        inner.canExecute(storage: storage, selection: selection)
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        inner.transaction(storage: storage, selection: selection, env: env)
    }
}

public struct DeleteTableRowCommand: Command {
    public let id = "deleteTableRow"
    public init() {}
    private let inner = TableMutationCommand(id: "deleteTableRow", label: "Delete Row") { model, row, _ in
        guard row >= 0 else { return nil } // refuse on header / alignment
        return model.deletingRow(at: row)
    }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        inner.canExecute(storage: storage, selection: selection)
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        inner.transaction(storage: storage, selection: selection, env: env)
    }
}

public struct InsertTableColumnBeforeCommand: Command {
    public let id = "insertTableColumnBefore"
    public init() {}
    private let inner = TableMutationCommand(id: "insertTableColumnBefore", label: "Insert Column Left") { model, _, col in
        model.insertingColumn(after: col - 1)
    }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        inner.canExecute(storage: storage, selection: selection)
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        inner.transaction(storage: storage, selection: selection, env: env)
    }
}

public struct InsertTableColumnAfterCommand: Command {
    public let id = "insertTableColumnAfter"
    public init() {}
    private let inner = TableMutationCommand(id: "insertTableColumnAfter", label: "Insert Column Right") { model, _, col in
        model.insertingColumn(after: col)
    }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        inner.canExecute(storage: storage, selection: selection)
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        inner.transaction(storage: storage, selection: selection, env: env)
    }
}

public struct DeleteTableColumnCommand: Command {
    public let id = "deleteTableColumn"
    public init() {}
    private let inner = TableMutationCommand(id: "deleteTableColumn", label: "Delete Column") { model, _, col in
        guard model.columnCount > 1 else { return nil }
        return model.deletingColumn(at: col)
    }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        inner.canExecute(storage: storage, selection: selection)
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        inner.transaction(storage: storage, selection: selection, env: env)
    }
}

public struct SetTableColumnAlignmentCommand: Command {
    public let alignment: PipeTableAlignment
    public var id: String { "setTableColumnAlignment" }
    public init(alignment: PipeTableAlignment) { self.alignment = alignment }

    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        tableContext(storage: storage, selection: selection) != nil
    }

    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard let ctx = tableContext(storage: storage, selection: selection),
              let cursor = tableCursor(storage: storage, selection: selection, model: ctx.model) else { return nil }
        let mutated = ctx.model.settingAlignment(alignment, forColumn: cursor.column)
        return Transaction(
            steps: [replaceTable(storage: storage, tableRange: ctx.range, with: mutated, env: env)],
            label: "Set Column Alignment"
        )
    }
}

// MARK: - Cell text edit (called by the SwiftUI sheet, not the menu)

/// Build a transaction that replaces a single cell's text. Public entry
/// point for `EditorController.applyTableCellEdit`. Returns nil if the
/// table at `tableRange` no longer parses (e.g. user typed into raw mode
/// and broke the structure between sheet open and save).
public func makeSetTableCellTextTransaction(
    storage: NSTextStorage,
    tableRange: NSRange,
    row: Int,
    column: Int,
    text: String,
    env: StepEnvironment
) -> Transaction? {
    let probe = max(0, min(tableRange.location, storage.length - 1))
    guard probe < storage.length, let model = PipeTableModel.parse(at: probe, in: storage) else { return nil }
    let mutated = model.settingCellText(text, row: row, column: column)
    return Transaction(
        steps: [replaceTable(storage: storage, tableRange: model.sourceRange, with: mutated, env: env)],
        label: "Edit Cell"
    )
}
