import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension EditorController {
    @_spi(Harness) public func settleForHarness() {
        flushDocumentChanges()
        drainDeferredEdits()
        flushDocumentChanges()
        refreshInlineContentIfNeeded()
    }

    @_spi(Harness) public var hasPendingWorkForHarness: Bool {
        hasPendingDocumentChange || !deferredEdits.isEmpty
    }

    @_spi(Harness) public var activeUndoManagerForHarness: UndoManager {
        #if canImport(AppKit) && os(macOS)
        if let manager = hostTextView?.undoManager { return manager }
        #endif
        return editSession.undoManager
    }

    @_spi(Harness) public func breakUndoCoalescingForHarness() {
        #if canImport(AppKit) && os(macOS)
        hostTextView?.breakUndoCoalescing()
        #endif
    }

    @_spi(Harness) public var harnessEditRouteProbe: ((String) -> Void)? {
        get { harnessRouteProbe }
        set { harnessRouteProbe = newValue }
    }

    @_spi(Harness) public func harnessNormalizationDrift() -> String? {
        let copy = NSMutableAttributedString(attributedString: textStorage)
        let full = NSRange(location: 0, length: copy.length)
        let before = VocabularySnapshot(capturing: copy, in: full)
        let listsBefore = Self.listShapes(in: copy)
        normalizer.normalizeAll(copy)
        restyler.restyleAll(copy)
        if copy.string != textStorage.string { return "normalizer changed the text" }
        if !before.matches(copy) {
            let changed = Self.firstVocabularyDifference(textStorage, copy)
            return "normalizer or restyler changed the vocabulary at \(changed)"
        }
        let listsAfter = Self.listShapes(in: copy)
        if listsAfter != listsBefore {
            let index = listsBefore.indices.first { $0 >= listsAfter.count || listsBefore[$0] != listsAfter[$0] } ?? listsBefore.count
            return "normalizer changed the text lists of paragraph \(index)"
        }
        return nil
    }

    @_spi(Harness) public func harnessTableGeometry(at index: Int) -> (row: Int, rows: Int, columns: Int)? {
        guard index >= 0, index < textStorage.length,
              let geometry = textStorage.attribute(.markdownTableGeometry, at: index, effectiveRange: nil) as? TableRowGeometry
        else { return nil }
        return (geometry.rowIndex, geometry.rowCount, max(0, geometry.columnEdges.count - 1))
    }
}

extension EditorController {
    func emitHostEditRoute(replacement: String?) {
        guard let probe = harnessRouteProbe, !isApplyingCommand else { return }
        let manager = editSession.undoManager
        if manager.isUndoing || manager.isRedoing {
            probe(manager.isUndoing ? "undo" : "redo")
        } else if hostHasMarkedText || isSettingMarkedText {
            probe("composition")
        } else if let replacement {
            probe(replacement.isEmpty ? "deletion" : replacement.count == 1 ? "typing" : "bulk")
        }
    }

    func emitHistoryRoute() {
        guard let probe = harnessRouteProbe else { return }
        let manager = editSession.undoManager
        if manager.isUndoing { probe("undo") } else if manager.isRedoing { probe("redo") }
    }

    private static func listShapes(in storage: NSAttributedString) -> [[Bool]] {
        storage.markdownParagraphRanges().map { paragraph in
            guard paragraph.length > 0,
                  let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            else { return [] }
            return style.textLists.filter { !$0.markerFormat.rawValue.isEmpty }.map(\.hasOrderedMarker)
        }
    }

    private static func firstVocabularyDifference(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> Int {
        let length = min(lhs.length, rhs.length)
        var index = 0
        while index < length {
            var lhsRange = NSRange(), rhsRange = NSRange()
            let left = lhs.attributes(at: index, effectiveRange: &lhsRange)
            let right = rhs.attributes(at: index, effectiveRange: &rhsRange)
            for key in VocabularySnapshot.keys where !Self.same(left[key], right[key]) { return index }
            index = max(index + 1, min(NSMaxRange(lhsRange), NSMaxRange(rhsRange)))
        }
        return length
    }

    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (l?, r?): (l as AnyObject).isEqual(r)
        default: false
        }
    }
}
