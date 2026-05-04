import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct StoredInlineMarkTests {

    @Test func performBoldOnEmptySelectionDoesNotInsertText() throws {
        let controller = try EditorController(initialMarkdown: "ready\n")
        let before = controller.markdown()
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.bold)
        #expect(controller.markdown() == before)
    }

    @Test func performBoldOnEmptySelectionStoresMark() throws {
        let controller = try EditorController(initialMarkdown: "x\n")
        controller.testSelection = NSRange(location: 1, length: 0)
        controller.perform(.bold)
        #expect(controller.storedInlineMarks == [.bold])
    }

    @Test func togglingSameMarkTwiceOnEmptySelectionClearsIt() throws {
        let controller = try EditorController(initialMarkdown: "x\n")
        controller.testSelection = NSRange(location: 1, length: 0)
        controller.perform(.italic)
        #expect(controller.storedInlineMarks == [.italic])
        controller.perform(.italic)
        #expect(controller.storedInlineMarks.isEmpty)
    }

    @Test func togglingTwoDifferentMarksAccumulatesThem() throws {
        let controller = try EditorController(initialMarkdown: "x\n")
        controller.testSelection = NSRange(location: 1, length: 0)
        controller.perform(.bold)
        controller.perform(.italic)
        #expect(controller.storedInlineMarks == [.bold, .italic])
    }

    @Test func movingSelectionElsewhereDropsStoredMarks() throws {
        let controller = try EditorController(initialMarkdown: "alpha\n")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.bold)
        #expect(controller.storedInlineMarks == [.bold])
        // A non-mark perform at a different location triggers refreshTypingAttributes
        // at the new cursor; storedMarks anchored at 0 should be dropped.
        controller.testSelection = NSRange(location: 3, length: 0)
        controller.perform(.italic)
        // Now only italic is stored at the new location.
        #expect(controller.storedInlineMarks == [.italic])
    }

    @Test func performBoldOnSelectionStillToggles() throws {
        let controller = try EditorController(initialMarkdown: "alpha beta\n")
        controller.testSelection = NSRange(location: 0, length: 5)
        controller.perform(.bold)
        #expect(controller.markdown().contains("**alpha**"))
        // No stored marks should leak when selection toggle is the path taken.
        #expect(controller.storedInlineMarks.isEmpty)
    }
}
