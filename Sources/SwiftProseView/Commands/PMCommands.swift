import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// PM-shaped commands. Most are stubs returning nil until the structural
// transform helpers in Transforms.swift gain Step-builder bodies; the
// types exist so chainCommands can wire the names up today.

public struct SelectAllCommand: Command {
    public let id = "selectAll"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        storage.length > 0
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        var tx = Transaction(label: "Select All")
        tx.selection = .text(
            range: NSRange(location: 0, length: storage.length),
            anchor: 0,
            head: storage.length
        )
        return tx
    }
}

/// PM's `splitBlock` — split the textblock at the cursor. SwiftProse
/// drives this through `EditorController.handleNewline`; this command is
/// a thin shim so chainCommands can name it.
public struct SplitBlockCommand: Command {
    public let id = "splitBlock"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        // Hand off to the existing newline-insertion path. Returning nil
        // lets a chained fallback (splitBlockKeepMarks, default newline)
        // handle the case.
        nil
    }
}

public struct SplitBlockKeepMarksCommand: Command {
    public let id = "splitBlockKeepMarks"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct LiftEmptyBlockCommand: Command {
    public let id = "liftEmptyBlock"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct LiftCommand: Command {
    public let id = "lift"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct JoinBackwardCommand: Command {
    public let id = "joinBackward"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        selection.length == 0 && selection.location > 0
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct JoinForwardCommand: Command {
    public let id = "joinForward"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        selection.length == 0 && selection.location < storage.length
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct JoinUpCommand: Command {
    public let id = "joinUp"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct JoinDownCommand: Command {
    public let id = "joinDown"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

/// PM's `selectNodeBackward` — select the atomic node immediately before
/// the cursor when the cursor is at the start of a textblock.
public struct SelectNodeBackwardCommand: Command {
    public let id = "selectNodeBackward"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        selection.length == 0 && selection.location > 0
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard selection.length == 0, selection.location > 0 else { return nil }
        let probe = selection.location - 1
        guard let path = storage.nodePath(at: probe), let leaf = path.leaf else { return nil }
        if leaf.type == "horizontal_rule" || leaf.type == "image" {
            var tx = Transaction(label: "Select Node")
            tx.selection = .node(path: path, range: NSRange(location: probe, length: 1))
            return tx
        }
        return nil
    }
}

public struct SelectNodeForwardCommand: Command {
    public let id = "selectNodeForward"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool {
        selection.length == 0 && selection.location < storage.length
    }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        guard selection.length == 0, selection.location < storage.length else { return nil }
        guard let path = storage.nodePath(at: selection.location), let leaf = path.leaf else { return nil }
        if leaf.type == "horizontal_rule" || leaf.type == "image" {
            var tx = Transaction(label: "Select Node")
            tx.selection = .node(path: path, range: NSRange(location: selection.location, length: 1))
            return tx
        }
        return nil
    }
}

public struct SelectParentNodeCommand: Command {
    public let id = "selectParentNode"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? { nil }
}

public struct SelectTextblockStartCommand: Command {
    public let id = "selectTextblockStart"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRange = (storage.string as NSString).lineRange(for: NSRange(location: selection.location, length: 0))
        var tx = Transaction(label: "Select Textblock Start")
        tx.selection = .text(
            range: NSRange(location: lineRange.location, length: 0),
            anchor: lineRange.location,
            head: lineRange.location
        )
        return tx
    }
}

public struct SelectTextblockEndCommand: Command {
    public let id = "selectTextblockEnd"
    public init() {}
    public func canExecute(storage: NSAttributedString, selection: NSRange) -> Bool { true }
    public func transaction(storage: NSTextStorage, selection: NSRange, env: StepEnvironment) -> Transaction? {
        let lineRange = (storage.string as NSString).lineRange(for: NSRange(location: selection.location, length: 0))
        let end = lineRange.location + max(0, lineRange.length - 1) // exclude trailing \n
        var tx = Transaction(label: "Select Textblock End")
        tx.selection = .text(
            range: NSRange(location: end, length: 0),
            anchor: end,
            head: end
        )
        return tx
    }
}
