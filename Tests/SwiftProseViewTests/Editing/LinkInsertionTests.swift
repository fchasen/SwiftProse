import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Link insertion")
@MainActor
struct LinkInsertionTests {
    private func editor(_ markdown: String, selecting range: NSRange) -> HeadlessEditor {
        let editor = HeadlessEditor(markdown: markdown)
        editor.controller.setSelection(range)
        return editor
    }

    @Test func linkActionKeepsTheSelectionAsLabel() {
        let editor = editor("this is a url to link to", selecting: NSRange(location: 10, length: 3))
        editor.controller.perform(.link)
        #expect(editor.string == "this is a url to link to")
        #expect(editor.controller.markdown() == "this is a [url](url) to link to")
        #expect(editor.selection == NSRange(location: 13, length: 0))
        #expect(editor.link(at: 11) == "url")
        #expect(editor.linkRange(at: 11) == NSRange(location: 10, length: 3))
    }

    @Test func linkActionWithoutSelectionInsertsTheLabel() {
        let editor = editor("ab", selecting: NSRange(location: 1, length: 0))
        editor.controller.perform(.link(url: "https://example.com", label: "docs"))
        #expect(editor.controller.markdown() == "a[docs](https://example.com)b")
        #expect(editor.selection == NSRange(location: 5, length: 0))
        editor.controller.perform(.link)
        #expect(editor.controller.markdown() == "adocsb")
    }

    @Test func insertLinkStampsTheMark() {
        let editor = editor("read the docs now", selecting: NSRange(location: 9, length: 4))
        #expect(editor.controller.insertLink(label: "ignored", url: "https://example.com"))
        #expect(editor.selection == NSRange(location: 13, length: 0))
        #expect(editor.controller.markdown() == "read the [docs](https://example.com) now")
        #expect(editor.link(at: 9) == "https://example.com")
        #expect(editor.link(at: 12) == "https://example.com")
        #expect(editor.link(at: 13) == nil)
    }

    @Test func linkIsOneUndoUnit() {
        let editor = editor("this is a url to link to", selecting: NSRange(location: 10, length: 3))
        editor.controller.perform(.link)
        editor.controller.undoManager.undo()
        #expect(editor.controller.markdown() == "this is a url to link to")
        #expect(editor.link(at: 10) == nil)
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
