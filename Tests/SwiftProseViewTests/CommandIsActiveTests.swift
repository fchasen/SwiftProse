import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct CommandIsActiveTests {

    private func controller(_ markdown: String) throws -> EditorController {
        try EditorController(initialMarkdown: markdown, theme: .default)
    }

    @Test func boldActiveInsideStrongSpan() throws {
        let c = try controller("**hi** there\n")
        let inside = (c.textStorage.string as NSString).range(of: "hi")
        c.testSelection = (NSRange(location: inside.location + 1, length: 0))
        #expect(c.isActionActive(.bold))
        #expect(!c.isActionActive(.italic))
    }

    @Test func boldInactiveOutsideStrongSpan() throws {
        let c = try controller("**hi** there\n")
        let outside = (c.textStorage.string as NSString).range(of: "there")
        c.testSelection = (NSRange(location: outside.location + 1, length: 0))
        #expect(!c.isActionActive(.bold))
    }

    @Test func storedInlineMarksLightUpButton() throws {
        let c = try controller("hello\n")
        // Empty selection, no bold yet.
        c.testSelection = (NSRange(location: 5, length: 0))
        #expect(!c.isActionActive(.bold))
        // perform(.bold) on an empty selection is the public path that
        // toggles stored marks — caret-only bold mode.
        c.perform(.bold)
        #expect(c.isActionActive(.bold))
        // Move cursor — stored marks clear, button goes off.
        c.testSelection = (NSRange(location: 0, length: 0))
        #expect(!c.isActionActive(.bold))
    }

    @Test func mixedBoldSelectionIsNotActive() throws {
        let c = try controller("**bold** plain\n")
        let storage = c.textStorage
        let totalLen = storage.length - 1
        c.testSelection = (NSRange(location: 0, length: totalLen))
        #expect(!c.isActionActive(.bold), "Selection straddling bold + plain should not read as active.")
    }

    @Test func headingActiveOnHeadingLine() throws {
        let c = try controller("# Title\n\nbody\n")
        c.testSelection = (NSRange(location: 2, length: 0)) // inside the heading
        #expect(c.isActionActive(.heading(level: 1)))
        #expect(!c.isActionActive(.heading(level: 2)))
    }

    @Test func headingInactiveOnBodyLine() throws {
        let c = try controller("# Title\n\nbody\n")
        let body = (c.textStorage.string as NSString).range(of: "body")
        c.testSelection = (NSRange(location: body.location + 1, length: 0))
        #expect(!c.isActionActive(.heading(level: 1)))
    }

    @Test func unorderedListActiveOnListItem() throws {
        let c = try controller("- one\n- two\n")
        let two = (c.textStorage.string as NSString).range(of: "two")
        c.testSelection = (NSRange(location: two.location + 1, length: 0))
        #expect(c.isActionActive(.unorderedList))
        #expect(!c.isActionActive(.orderedList))
    }

    @Test func blockquoteActiveInsideQuote() throws {
        let c = try controller("> quoted\n\nplain\n")
        let inside = (c.textStorage.string as NSString).range(of: "quoted")
        c.testSelection = (NSRange(location: inside.location + 1, length: 0))
        #expect(c.isActionActive(.blockquote))
        let plain = (c.textStorage.string as NSString).range(of: "plain")
        c.testSelection = (NSRange(location: plain.location + 1, length: 0))
        #expect(!c.isActionActive(.blockquote))
    }

    @Test func activeActionIDsCollectsAll() throws {
        let c = try controller("**bold** text\n")
        let inside = (c.textStorage.string as NSString).range(of: "bold")
        c.testSelection = (NSRange(location: inside.location + 1, length: 0))
        let ids = c.activeActionIDs()
        #expect(ids.contains("bold"))
        #expect(!ids.contains("italic"))
    }
}
