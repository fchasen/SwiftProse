#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite(.serialized)
@MainActor
struct ListEditingFlowTests {
    private func bulletEditor(typing text: String) -> EditorHarness {
        let harness = EditorHarness(markdown: "")
        harness.step { harness.controller.perform(.unorderedList) }
        harness.type(text)
        return harness
    }

    private func deleteAll(_ harness: EditorHarness) {
        harness.select(NSRange(location: 0, length: harness.storage.length))
        harness.deleteBackward()
    }

    @Test func clickBulletOnEmptyEditorRendersBullet() {
        let harness = EditorHarness(markdown: "")
        harness.step { harness.controller.perform(.unorderedList) }
        #expect(harness.controller.isActive(.unorderedList))
        harness.type("one")
        #expect(harness.block(at: 0)?.isListItemStart == true)
        #expect(harness.textLists(at: 0).count == 1)
        #expect(harness.markdown == "- one")
    }

    @Test func clickBulletThenTypeThenReturnCreatesSecondItem() {
        let harness = bulletEditor(typing: "one")
        harness.insertNewline()
        #expect(harness.controller.paragraphInfo(at: harness.selection.location).block.isListItemStart)
        harness.type("two")
        #expect(harness.markdown == "- one\n- two")
        #expect(harness.textLists(at: 4).first === harness.textLists(at: 0).first)
    }

    @Test func clickBulletEmptyEditorThenTypeThenReturnReturnExitsList() {
        let harness = bulletEditor(typing: "one")
        harness.insertNewline()
        harness.insertNewline()
        #expect(harness.markdown == "- one")
        harness.type("x")
        #expect(harness.markdown == "- one\n\nx")
        #expect(harness.block(at: harness.storage.length - 1)?.isListItem == false)
    }

    @Test func deleteAllThenChangeDocumentThenType() {
        let harness = bulletEditor(typing: "first bug content")
        deleteAll(harness)
        harness.controller.setMarkdown("second bug content\n")
        #expect(harness.string.contains("second bug content"))
        harness.select(harness.storage.length)
        harness.type(" extended")
        #expect(harness.markdown.contains("second bug content extended"))
    }

    @Test func typingAfterDeleteAllAddsContent() {
        let harness = bulletEditor(typing: "fred")
        deleteAll(harness)
        #expect(harness.storage.length == 0)
        harness.type("hello")
        #expect(harness.string == "hello")
        #expect(harness.markdown == "hello")
    }

    @Test func deleteAllTextFromList() {
        let harness = bulletEditor(typing: "fred")
        harness.insertNewline()
        harness.type("is")
        #expect(harness.markdown == "- fred\n- is")
        deleteAll(harness)
        #expect(harness.storage.length == 0)
        #expect(harness.markdown == "")
    }

    @Test func aListNumbersFromItsFirstMarker() {
        #expect(EditorController(markdown: "5. one\n6. two\n").serialize() == "5. one\n6. two")
        #expect(EditorController(markdown: "5. one\n9. two\n").serialize() == "5. one\n6. two")
    }
}
#endif
