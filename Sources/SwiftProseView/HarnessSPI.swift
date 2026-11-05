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
        let before = VocabularySnapshot(capturing: copy, in: NSRange(location: 0, length: copy.length))
        normalizer.normalizeAll(copy)
        restyler.restyleAll(copy)
        guard !before.matches(copy) else { return nil }
        return "normalizer or restyler changed the storage vocabulary"
    }

    @_spi(Harness) public func harnessTableGeometry(at index: Int) -> (row: Int, rows: Int, columns: Int)? {
        guard index >= 0, index < textStorage.length,
              let geometry = textStorage.attribute(.markdownTableGeometry, at: index, effectiveRange: nil) as? TableRowGeometry
        else { return nil }
        return (geometry.rowIndex, geometry.rowCount, max(0, geometry.columnEdges.count - 1))
    }
}
