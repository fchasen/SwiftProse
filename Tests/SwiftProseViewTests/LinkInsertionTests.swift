import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

@Suite(.serialized) struct LinkInsertionTests {

    private func controller(_ markdown: String, selecting: NSRange) throws -> EditorController {
        let c = try EditorController(initialMarkdown: markdown, theme: .default)
        c.testSelection = selecting
        return c
    }

    @Test func linkActionKeepsTheSelectionAsLabel() throws {
        let c = try controller("this is a url to link to", selecting: NSRange(location: 10, length: 3))
        let out = c.perform(.link)
        #expect(c.textStorage.string.hasPrefix("this is a url to link to"))
        #expect(c.markdown() == "this is a [url](url) to link to")
        #expect(out == NSRange(location: 13, length: 0))
        let mark = try #require(c.linkMark(at: 11))
        #expect(mark.range == NSRange(location: 10, length: 3))
        #expect(mark.href == "url")
    }

    @Test func linkActionWithURLUsesIt() throws {
        let c = try controller("this is a url to link to", selecting: NSRange(location: 10, length: 3))
        _ = c.perform(.link(url: "https://example.com"))
        #expect(c.markdown() == "this is a [url](https://example.com) to link to")
        #expect(c.linkMark(at: 10)?.href == "https://example.com")
    }

    @Test func selectedURLBecomesItsOwnDestination() throws {
        let c = try controller("see https://example.com today", selecting: NSRange(location: 4, length: 19))
        _ = c.perform(.link)
        #expect(c.markdown() == "see [https://example.com](https://example.com) today")
    }

    @Test func linkActionWithoutSelectionInsertsTheLabel() throws {
        let c = try controller("ab", selecting: NSRange(location: 1, length: 0))
        _ = c.perform(.link(url: "https://example.com", label: "docs"))
        #expect(c.markdown() == "a[docs](https://example.com)b")
        _ = c.perform(.link)
        #expect(c.markdown().contains("[link](url)"))
    }

    @Test func insertLinkStampsTheMark() throws {
        let c = try controller("read the docs now", selecting: NSRange(location: 9, length: 4))
        let out = c.insertLink(label: "ignored", url: "https://example.com")
        #expect(out == NSRange(location: 13, length: 0))
        #expect(c.markdown() == "read the [docs](https://example.com) now")
        #expect(c.linkMark(at: 9)?.href == "https://example.com")
        #expect(c.document.resolve(10)?.marks().mark(of: "link") != nil)
    }

    @Test func linkIsOneUndoUnit() throws {
        let c = try controller("this is a url to link to", selecting: NSRange(location: 10, length: 3))
        _ = c.perform(.link)
        c.undoManager.undo()
        #expect(c.markdown() == "this is a url to link to")
        #expect(c.linkMark(at: 10) == nil)
    }

    @Test func looksLikeURL() {
        #expect(EditorController.looksLikeURL("https://example.com/a?b=c"))
        #expect(EditorController.looksLikeURL("mailto:a@b.c"))
        #expect(EditorController.looksLikeURL("www.example.com"))
        #expect(!EditorController.looksLikeURL("url"))
        #expect(!EditorController.looksLikeURL("not a url"))
        #expect(!EditorController.looksLikeURL(""))
    }
}
