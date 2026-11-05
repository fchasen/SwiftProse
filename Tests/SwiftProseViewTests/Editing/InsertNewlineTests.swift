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
struct InsertNewlineTests {
    private func blockCount(_ harness: EditorHarness) -> Int {
        StorageReader().document(from: harness.storage).blocks.count
    }

    private func location(of needle: String, in harness: EditorHarness) -> Int {
        let location = (harness.string as NSString).range(of: needle).location
        precondition(location != NSNotFound, "no \(needle) in storage")
        return location
    }

    @Test func nonListReturnsNil() {
        let editor = HeadlessEditor(markdown: "hello\n")
        editor.select(5)
        #expect(!editor.controller.handleNewline())
        #expect(editor.controller.markdown() == "hello\n")
    }

    @Test func emptyBulletTerminatesList() {
        let harness = EditorHarness(markdown: "- one\n-\n")
        harness.select(4)
        #expect(harness.block(at: 4)?.isListItemStart == true)
        harness.insertNewline()
        #expect(harness.markdown == "- one")
        #expect(harness.block(at: 4)?.isListItem == false)
        harness.type("x")
        #expect(harness.markdown == "- one\n\nx")
        #expect(harness.block(at: harness.storage.length - 1)?.isListItem == false)
    }

    @Test func doubleReturnEndsList() {
        let harness = EditorHarness(markdown: "- one\n")
        harness.select(harness.storage.length)
        harness.insertNewline()
        harness.insertNewline()
        #expect(harness.markdown == "- one")
        harness.type("x")
        #expect(harness.block(at: harness.storage.length - 1)?.isListItem == false)
        #expect(harness.markdown == "- one\n\nx")
    }

    @Test func orderedListIncrements() {
        let harness = EditorHarness(markdown: "1. apple\n")
        harness.select(harness.storage.length)
        harness.insertNewline()
        harness.type("pear")
        #expect(harness.markdown == "1. apple\n2. pear")
    }

    @Test func returnAtItemStartOpensEmptyItemAbove() {
        let harness = EditorHarness(markdown: "- one\n")
        harness.select(0)
        harness.insertNewline()
        #expect(harness.paragraphTexts == ["", "one"])
        #expect(harness.selection == NSRange(location: 1, length: 0))
        #expect(harness.block(at: 0)?.isListItemStart == true)
        #expect(harness.block(at: 1)?.isListItemStart == true)
        harness.select(0)
        harness.type("zero")
        #expect(harness.markdown == "- zero\n- one")
    }

    @Test func returnMidItemMovesTailToNewItem() {
        let harness = EditorHarness(markdown: "- onetwo\n")
        harness.select(3)
        harness.insertNewline()
        #expect(harness.markdown == "- one\n- two")
        #expect(harness.selection == NSRange(location: 4, length: 0))
    }

    @Test func returnWithSelectionInsideItemDeletesItFirst() {
        let harness = EditorHarness(markdown: "- onetwo\n")
        harness.select(NSRange(location: 2, length: 2))
        harness.insertNewline()
        #expect(harness.markdown == "- on\n- wo")
        #expect(harness.selection == NSRange(location: 3, length: 0))
    }

    @Test func returnAtItemStartKeepsOneList() {
        let harness = EditorHarness(markdown: "- one\n- two\n- three\n")
        harness.select(location(of: "two", in: harness))
        harness.insertNewline()
        harness.type("X")
        #expect(harness.string == "one\n\nXtwo\nthree")
        harness.select(4)
        harness.type("new")
        #expect(harness.markdown == "- one\n- new\n- Xtwo\n- three")
        #expect(blockCount(harness) == 1)
        #expect(harness.textLists(at: 4).first === harness.textLists(at: 0).first)
    }

    @Test func returnMidItemKeepsOneList() {
        let harness = EditorHarness(markdown: "- one\n- twothree\n")
        harness.select(location(of: "three", in: harness))
        harness.insertNewline()
        #expect(harness.markdown == "- one\n- two\n- three")
        #expect(harness.selection.location == location(of: "three", in: harness))
        #expect(blockCount(harness) == 1)
    }

    @Test func returnAtOrderedItemStartRenumbers() {
        let harness = EditorHarness(markdown: "1. apple\n2. pear\n3. plum\n")
        harness.select(location(of: "pear", in: harness))
        harness.insertNewline()
        harness.type("X")
        harness.select(location(of: "Xpear", in: harness) - 1)
        harness.type("peach")
        #expect(harness.markdown == "1. apple\n2. peach\n3. Xpear\n4. plum")
        #expect(blockCount(harness) == 1)
    }

    @Test func returnAtCheckedTaskStartKeepsCheckOnContent() {
        let harness = EditorHarness(markdown: "- [x] done\n")
        harness.select(0)
        harness.insertNewline()
        harness.select(0)
        harness.type("next")
        #expect(harness.markdown == "- [ ] next\n- [x] done")
    }

    @Test func returnAtNestedItemStartStaysNested() {
        let harness = EditorHarness(markdown: "- one\n  - two\n")
        harness.select(location(of: "two", in: harness))
        harness.insertNewline()
        harness.select(location(of: "two", in: harness) - 1)
        harness.type("mid")
        #expect(harness.markdown == "- one\n  - mid\n  - two")
    }

    @Test func returnMidItemKeepsMarksOnMovedText() {
        let harness = EditorHarness(markdown: "- one**two**\n")
        harness.select(3)
        harness.insertNewline()
        #expect(harness.markdown == "- one\n- **two**")
    }
}
#endif
