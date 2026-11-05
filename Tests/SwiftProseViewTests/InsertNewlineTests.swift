import Testing
import Foundation
import SwiftProseSyntax
import SwiftProseRendering
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct InsertNewlineTests {

    private func storage(from markdown: String) throws -> NSTextStorage {
        let compiler = try MarkdownAttributedCompiler()
        let attr = compiler.compile(markdown, theme: .default)
        return NSTextStorage(attributedString: attr)
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        AttributedMarkdownSerializer().serialize(storage)
    }

    private func handle(in storage: NSTextStorage, cursor: Int) throws -> NSRange? {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        return InsertNewline.handle(
            in: storage,
            cursor: cursor,
            compiler: compiler,
            serializer: serializer,
            theme: .default
        )
    }

    private func handle(in storage: NSTextStorage, selection: NSRange) throws -> NSRange? {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        return InsertNewline.handle(
            in: storage,
            selection: selection,
            compiler: compiler,
            serializer: serializer,
            theme: .default
        )
    }

    @Test func nonListReturnsNil() throws {
        let s = try storage(from: "hello\n")
        #expect(try handle(in: s, cursor: 5) == nil)
    }

    @Test func bulletListContinues() throws {
        let s = try storage(from: "- one\n")
        let result = try handle(in: s, cursor: s.length - 1)
        #expect(result != nil)
        #expect(serialize(s) == "- one\n- \n")
    }

    @Test func emptyBulletTerminatesList() throws {
        let controller = try EditorController(initialMarkdown: "- one\n- \n")
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        #expect(controller.handleNewline())
        // Empty list line drops back to a plain paragraph — markdown round-trip
        // collapses the trailing blank paragraph, so the saved source is just
        // the surviving list item.
        #expect(controller.markdown() == "- one")
        let lineLoc = controller.textStorage.length - 1
        let spec = controller.textStorage.blockSpec(at: lineLoc)
        #expect(spec?.isListItem == false || spec == nil)
    }

    @Test func doubleReturnEndsList() throws {
        let controller = try EditorController(initialMarkdown: "- one\n")
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        #expect(controller.handleNewline())
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        #expect(controller.handleNewline())
        #expect(controller.markdown() == "- one")
        let lineLoc = controller.textStorage.length - 1
        let spec = controller.textStorage.blockSpec(at: lineLoc)
        #expect(spec?.isListItem == false || spec == nil)
    }

    @Test func orderedListIncrements() throws {
        let s = try storage(from: "1. apple\n")
        _ = try handle(in: s, cursor: s.length - 1)
        #expect(serialize(s) == "1. apple\n2. \n")
    }

    @Test func taskListContinues() throws {
        let s = try storage(from: "- [x] done\n")
        _ = try handle(in: s, cursor: s.length - 1)
        let out = serialize(s)
        #expect(out.contains("- [x] done"))
        #expect(out.contains("- [ ] "))
    }

    @Test func returnAtItemStartOpensEmptyItemAbove() throws {
        let s = try storage(from: "- one\n")
        let result = try handle(in: s, cursor: 2)
        #expect(serialize(s) == "- \n- one\n")
        #expect(result == NSRange(location: 5, length: 0))
    }

    @Test func returnBeforeMarkerCountsAsItemStart() throws {
        let s = try storage(from: "- one\n")
        let result = try handle(in: s, cursor: 0)
        #expect(serialize(s) == "- \n- one\n")
        #expect(result == NSRange(location: 5, length: 0))
    }

    @Test func returnMidItemMovesTailToNewItem() throws {
        let s = try storage(from: "- onetwo\n")
        let result = try handle(in: s, cursor: 5)
        #expect(serialize(s) == "- one\n- two\n")
        #expect(result == NSRange(location: 8, length: 0))
    }

    @Test func returnWithSelectionInsideItemDeletesItFirst() throws {
        let s = try storage(from: "- onetwo\n")
        let result = try handle(in: s, selection: NSRange(location: 4, length: 2))
        #expect(serialize(s) == "- on\n- wo\n")
        #expect(result == NSRange(location: 7, length: 0))
    }

    @Test func returnAtItemStartKeepsOneList() throws {
        let controller = try EditorController(initialMarkdown: "- one\n- two\n")
        controller.testSelection = NSRange(location: 2, length: 0)
        #expect(controller.handleNewline())
        #expect(controller.markdown() == "- \n- one\n- two")
        guard case .structural(_, let kids) = controller.document.root else {
            Issue.record("root is not structural")
            return
        }
        #expect(kids.count == 1)
    }

    @Test func returnMidItemKeepsOneList() throws {
        let controller = try EditorController(initialMarkdown: "- one\n- twothree\n")
        controller.testSelection = NSRange(location: 11, length: 0)
        #expect(controller.handleNewline())
        #expect(controller.markdown() == "- one\n- two\n- three")
        guard case .structural(_, let kids) = controller.document.root else {
            Issue.record("root is not structural")
            return
        }
        #expect(kids.count == 1)
    }

    @Test func returnAtOrderedItemStartRenumbers() throws {
        let controller = try EditorController(initialMarkdown: "1. apple\n2. pear\n")
        controller.testSelection = NSRange(location: 12, length: 0)
        #expect(controller.handleNewline())
        #expect(controller.markdown() == "1. apple\n2. \n3. pear")
    }

    @Test func returnAtCheckedTaskStartKeepsCheckOnContent() throws {
        let controller = try EditorController(initialMarkdown: "- [x] done\n")
        controller.testSelection = NSRange(location: 2, length: 0)
        #expect(controller.handleNewline())
        #expect(controller.markdown() == "- [ ] \n- [x] done")
    }

    @Test func returnAtNestedItemStartStaysNested() throws {
        let controller = try EditorController(initialMarkdown: "- one\n  - two\n")
        controller.testSelection = NSRange(location: 8, length: 0)
        #expect(controller.handleNewline())
        #expect(controller.markdown() == "- one\n  - \n  - two")
    }

    @Test func returnMidItemKeepsMarksOnMovedText() throws {
        let controller = try EditorController(initialMarkdown: "- one**two**\n")
        controller.testSelection = NSRange(location: 5, length: 0)
        #expect(controller.handleNewline())
        #expect(controller.markdown() == "- one\n- **two**")
    }

    @Test func nestedOrderedRendersAsAlpha() throws {
        let compiler = try MarkdownAttributedCompiler()
        let attr = compiler.compile("1. one\n   1. nested\n", theme: .default)
        let storage = NSTextStorage(attributedString: attr)
        let raw = storage.string
        #expect(raw.contains("a. "))
        #expect(raw.contains("1. one"))
    }

    @Test func bulletStorageHasAttachmentMarker() throws {
        let compiler = try MarkdownAttributedCompiler()
        let attr = compiler.compile("- one\n", theme: .default)
        let storage = NSTextStorage(attributedString: attr)
        // The first character should be U+FFFC carrying a BulletGlyphAttachment.
        let firstChar = (storage.string as NSString).character(at: 0)
        #expect(firstChar == 0xFFFC)
        let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil)
        #expect(attachment is SwiftProseRendering.BulletGlyphAttachment)
        // The second character should be a space.
        #expect((storage.string as NSString).substring(with: NSRange(location: 1, length: 1)) == " ")
        // The whole marker run should be flagged so the serializer drops it.
        let markerFlag = storage.attribute(.proseListMarker, at: 0, effectiveRange: nil) as? Bool
        #expect(markerFlag == true)
    }

    @Test func doubleNestedOrderedRendersAsRoman() throws {
        let compiler = try MarkdownAttributedCompiler()
        let attr = compiler.compile(
            "1. one\n   1. nested\n      1. deeper\n",
            theme: .default
        )
        let storage = NSTextStorage(attributedString: attr)
        let raw = storage.string
        #expect(raw.contains("i. "))
    }
}
