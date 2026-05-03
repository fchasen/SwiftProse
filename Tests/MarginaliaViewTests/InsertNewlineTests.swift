import Testing
import Foundation
import MarginaliaSyntax
import MarginaliaRendering
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct InsertNewlineTests {

    private func storage(from markdown: String) throws -> NSTextStorage {
        let compiler = try MarkdownAttributedCompiler()
        let attr = compiler.compile(markdown, dialect: .commonMark, mode: .rich, theme: .default)
        return NSTextStorage(attributedString: attr)
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        AttributedMarkdownSerializer().serialize(storage, dialect: .commonMark)
    }

    private func handle(in storage: NSTextStorage, cursor: Int) throws -> NSRange? {
        let compiler = try MarkdownAttributedCompiler()
        let serializer = AttributedMarkdownSerializer()
        return InsertNewline.handle(
            in: storage,
            cursor: cursor,
            compiler: compiler,
            serializer: serializer,
            dialect: .commonMark,
            mode: .rich,
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
        #expect(controller.markdown() == "- one\n")
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
        #expect(controller.markdown() == "- one\n")
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

    @Test func nestedOrderedRendersAsAlpha() throws {
        let compiler = try MarkdownAttributedCompiler()
        let attr = compiler.compile("1. one\n   1. nested\n", dialect: .commonMark, mode: .rich, theme: .default)
        let storage = NSTextStorage(attributedString: attr)
        let raw = storage.string
        #expect(raw.contains("a. "))
        #expect(raw.contains("1. one"))
    }

    @Test func bulletStorageHasAttachmentMarker() throws {
        let compiler = try MarkdownAttributedCompiler()
        let attr = compiler.compile("- one\n", dialect: .commonMark, mode: .rich, theme: .default)
        let storage = NSTextStorage(attributedString: attr)
        // The first character should be U+FFFC carrying a BulletGlyphAttachment.
        let firstChar = (storage.string as NSString).character(at: 0)
        #expect(firstChar == 0xFFFC)
        let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil)
        #expect(attachment is MarginaliaRendering.BulletGlyphAttachment)
        // The second character should be a space.
        #expect((storage.string as NSString).substring(with: NSRange(location: 1, length: 1)) == " ")
        // The whole marker run should be flagged so the serializer drops it.
        let markerFlag = storage.attribute(.marginaliaListMarker, at: 0, effectiveRange: nil) as? Bool
        #expect(markerFlag == true)
    }

    @Test func doubleNestedOrderedRendersAsRoman() throws {
        let compiler = try MarkdownAttributedCompiler()
        let attr = compiler.compile(
            "1. one\n   1. nested\n      1. deeper\n",
            dialect: .commonMark, mode: .rich, theme: .default
        )
        let storage = NSTextStorage(attributedString: attr)
        let raw = storage.string
        #expect(raw.contains("i. "))
    }
}
