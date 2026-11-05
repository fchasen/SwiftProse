#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Command isActive (macOS)", .serialized)
@MainActor
struct CommandIsActiveTests {
    private func caret(in harness: EditorHarness, after text: String, offset: Int = 1) {
        harness.select((harness.string as NSString).range(of: text).location + offset)
    }

    @Test func boldActiveInsideStrongSpan() {
        let harness = EditorHarness(markdown: "**hi** there\n")
        caret(in: harness, after: "hi")
        #expect(harness.controller.isActive(.bold))
        #expect(!harness.controller.isActive(.italic))
    }

    @Test func boldInactiveOutsideStrongSpan() {
        let harness = EditorHarness(markdown: "**hi** there\n")
        caret(in: harness, after: "there")
        #expect(!harness.controller.isActive(.bold))
    }

    @Test func storedInlineMarksLightUpButton() {
        let harness = EditorHarness(markdown: "hello\n")
        harness.select(5)
        #expect(!harness.controller.isActive(.bold))
        harness.controller.perform(.bold)
        #expect(harness.controller.isActive(.bold))
        harness.select(0)
        #expect(!harness.controller.isActive(.bold))
    }

    @Test func mixedBoldSelectionIsNotActive() {
        let harness = EditorHarness(markdown: "**bold** plain\n")
        harness.select(NSRange(location: 0, length: harness.storage.length))
        #expect(!harness.controller.isActive(.bold))
    }

    @Test func headingActiveOnHeadingLine() {
        let harness = EditorHarness(markdown: "# Title\n\nbody\n")
        caret(in: harness, after: "Title")
        #expect(harness.controller.isActive(.heading(level: 1)))
        #expect(!harness.controller.isActive(.heading(level: 2)))
    }

    @Test func headingInactiveOnBodyLine() {
        let harness = EditorHarness(markdown: "# Title\n\nbody\n")
        caret(in: harness, after: "body")
        #expect(!harness.controller.isActive(.heading(level: 1)))
    }

    @Test func unorderedListActiveOnListItem() {
        let harness = EditorHarness(markdown: "- one\n- two\n")
        caret(in: harness, after: "two")
        #expect(harness.controller.isActive(.unorderedList))
        #expect(!harness.controller.isActive(.orderedList))
    }

    @Test func blockquoteActiveInsideQuote() {
        let harness = EditorHarness(markdown: "> quoted\n\nplain\n")
        caret(in: harness, after: "quoted")
        #expect(harness.controller.isActive(.blockquote))
        caret(in: harness, after: "plain")
        #expect(!harness.controller.isActive(.blockquote))
    }

    @Test func activeActionIDsCollectsAll() {
        let harness = EditorHarness(markdown: "**bold** text\n")
        caret(in: harness, after: "bold")
        let ids = harness.controller.activeActionIDs()
        #expect(ids.contains(EditorAction.bold.stableID))
        #expect(!ids.contains(EditorAction.italic.stableID))
    }
}
#endif
