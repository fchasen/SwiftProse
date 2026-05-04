import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Table commands are stubbed as no-ops while the editor migrates to the
// tree-native model. Pipe-table source still parses and round-trips, but
// commands that mutate table structure are inert until tree-native tables
// land. The public types stay so callers (toolbar buttons, demo apps) can
// keep referencing them without changes.

public struct InsertTableCommand: Command {
    public let rows: Int
    public let columns: Int
    public var id: String { "insertTable" }
    public init(rows: Int = 2, columns: Int = 3) {
        self.rows = rows
        self.columns = columns
    }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { false }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct InsertTableRowAboveCommand: Command {
    public let id = "insertTableRowAbove"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { false }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct InsertTableRowBelowCommand: Command {
    public let id = "insertTableRowBelow"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { false }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct DeleteTableRowCommand: Command {
    public let id = "deleteTableRow"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { false }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct InsertTableColumnBeforeCommand: Command {
    public let id = "insertTableColumnBefore"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { false }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct InsertTableColumnAfterCommand: Command {
    public let id = "insertTableColumnAfter"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { false }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct DeleteTableColumnCommand: Command {
    public let id = "deleteTableColumn"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { false }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct SetTableColumnAlignmentCommand: Command {
    public let alignment: PipeTableAlignment
    public var id: String { "setTableColumnAlignment" }
    public init(alignment: PipeTableAlignment) { self.alignment = alignment }
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { false }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

/// Single-cell text edit hook. Returns nil while pipe tables aren't a
/// first-class editing surface.
public func makeSetTableCellTextTransaction(
    storage: NSTextStorage,
    tableRange: NSRange,
    row: Int,
    column: Int,
    text: String,
    env: StepEnvironment
) -> Transaction? {
    nil
}
