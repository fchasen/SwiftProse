import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

final class EditSession {
    unowned let controller: EditorController
    private(set) var depth = 0
    private(set) var currentActionName: String?

    var isPerforming: Bool { depth > 0 }

    init(controller: EditorController) {
        self.controller = controller
    }

    @discardableResult
    func perform(
        actionName: String,
        ranges: [NSRange],
        replacements: [String]?,
        ignoringEditability: Bool = false,
        _ body: (NSTextStorage) -> Void
    ) -> Bool {
        if let replacements, replacements.count != ranges.count { return false }
        let storage = controller.textStorage
        if isPerforming {
            body(storage)
            return true
        }
        guard controller.isEditable || ignoringEditability else { return false }
        unmarkHostText()
        let clamped = ranges.map { Normalizer.clamp($0, to: storage.length) }
        #if canImport(AppKit) && os(macOS)
        if let textView = controller.hostTextView, textView.isEditable {
            return performHosted(textView, actionName: actionName, ranges: clamped, replacements: replacements, body)
        }
        #endif
        return performSnapshot(actionName: actionName, ranges: clamped, body)
    }

    var undoManager: UndoManager {
        #if canImport(UIKit) && !os(macOS)
        if let manager = controller.hostTextView?.undoManager { return manager }
        #endif
        return controller.undoManager
    }

    #if canImport(AppKit) && os(macOS)
    private func performHosted(
        _ textView: NSTextView,
        actionName: String,
        ranges: [NSRange],
        replacements: [String]?,
        _ body: (NSTextStorage) -> Void
    ) -> Bool {
        textView.breakUndoCoalescing()
        let values = (ranges.isEmpty ? [NSRange(location: 0, length: 0)] : ranges).map { NSValue(range: $0) }
        let strings = ranges.isEmpty ? nil : replacements
        guard textView.shouldChangeText(inRanges: values, replacementStrings: strings) else { return false }
        run(actionName: actionName) {
            let storage = controller.textStorage
            storage.beginEditing()
            body(storage)
            storage.endEditing()
            textView.didChangeText()
        }
        if !actionName.isEmpty { textView.undoManager?.setActionName(actionName) }
        textView.breakUndoCoalescing()
        return true
    }
    #endif

    private func performSnapshot(actionName: String, ranges: [NSRange], _ body: (NSTextStorage) -> Void) -> Bool {
        let storage = controller.textStorage
        let affected = snapshotRange(for: ranges, in: storage)
        let snapshot = storage.attributedSubstring(from: affected)
        let selection = controller.currentSelection
        let lengthBefore = storage.length
        let manager = undoManager
        let after = RangeBox(NSRange(location: affected.location, length: affected.length))
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: controller) { [weak self, weak manager] _ in
            guard let manager else { return }
            self?.restore(range: after.range, snapshot: snapshot, selection: selection, actionName: actionName, manager: manager)
        }
        run(actionName: actionName) {
            storage.beginEditing()
            body(storage)
            storage.endEditing()
        }
        after.range.length = max(0, affected.length + storage.length - lengthBefore)
        if !actionName.isEmpty { manager.setActionName(actionName) }
        manager.endUndoGrouping()
        return true
    }

    private final class RangeBox {
        var range: NSRange

        init(_ range: NSRange) {
            self.range = range
        }
    }

    private func snapshotRange(for ranges: [NSRange], in storage: NSTextStorage) -> NSRange {
        guard let first = ranges.first else { return NSRange(location: 0, length: 0) }
        let union = ranges.dropFirst().reduce(first) { NSUnionRange($0, $1) }
        guard storage.length > 0 else { return union }
        let ns = storage.string as NSString
        return ns.paragraphRange(for: union)
    }

    private func registerRestore(
        on manager: UndoManager,
        range: NSRange,
        snapshot: NSAttributedString,
        selection: NSRange,
        actionName: String
    ) {
        manager.registerUndo(withTarget: controller) { [weak self, weak manager] _ in
            guard let manager else { return }
            self?.restore(range: range, snapshot: snapshot, selection: selection, actionName: actionName, manager: manager)
        }
    }

    private func restore(
        range: NSRange,
        snapshot: NSAttributedString,
        selection: NSRange,
        actionName: String,
        manager: UndoManager
    ) {
        let storage = controller.textStorage
        let target = Normalizer.clamp(range, to: storage.length)
        unmarkHostText()
        let current = storage.attributedSubstring(from: target)
        let currentSelection = controller.currentSelection
        let opensGroup = manager.groupingLevel == 0
        if opensGroup { manager.beginUndoGrouping() }
        defer { if opensGroup { manager.endUndoGrouping() } }
        registerRestore(
            on: manager,
            range: NSRange(location: target.location, length: snapshot.length),
            snapshot: current,
            selection: currentSelection,
            actionName: actionName
        )
        if !actionName.isEmpty { manager.setActionName(actionName) }
        run(actionName: actionName) {
            storage.beginEditing()
            storage.replaceCharacters(in: target, with: snapshot)
            storage.endEditing()
        }
        controller.setSelection(selection)
    }

    private func run(actionName: String, _ work: () -> Void) {
        let previousName = currentActionName
        depth += 1
        currentActionName = actionName
        defer {
            depth -= 1
            currentActionName = previousName
        }
        work()
    }

    private func unmarkHostText() {
        guard let textView = controller.hostTextView else { return }
        #if canImport(AppKit) && os(macOS)
        if textView.hasMarkedText() { textView.unmarkText() }
        #elseif canImport(UIKit)
        if textView.markedTextRange != nil { textView.unmarkText() }
        #endif
    }
}
