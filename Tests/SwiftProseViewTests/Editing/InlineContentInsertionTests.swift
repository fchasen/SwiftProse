import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite("Inline content insertion")
@MainActor
struct InlineContentInsertionTests {
    final class ProvidedAttachment: NSTextAttachment, ProseSourceAttachment {
        var markdownSource = ""
        var contentKind = ""
    }

    private let mention = ProseInlineContent.userMention(handle: "fred", displayName: "@fred")

    @Test func fallsBackToAChipLabelledByTheContent() throws {
        let editor = HeadlessEditor(markdown: "hi")
        editor.controller.insertInlineContent(mention, markdownSource: "@fred", replacing: NSRange(location: 2, length: 0))
        let chip = try #require(editor.controller.textStorage.proseSourceAttachment(at: 2) as? ChipTextAttachment)
        #expect(chip.chipLabel == "@fred")
        #expect(chip.chipSymbol == "person.crop.circle")
        #expect(chip.markdownSource == "@fred")
        #expect(chip.contentKind == "userMention")
    }

    @Test func usesTheProviderAttachment() throws {
        let controller = EditorController(
            markdown: "hi ",
            inlineContentProvider: { _ in ProvidedAttachment() }
        )
        controller.setSelection(NSRange(location: controller.textStorage.length, length: 0))
        controller.insertInlineContent(mention, markdownSource: "fred", replacing: controller.currentSelection)
        let attachment = try #require(controller.textStorage.proseSourceAttachment(at: 2) as? ProvidedAttachment)
        #expect(attachment.markdownSource == "fred")
        #expect(attachment.contentKind == "userMention")
    }

    @Test func serializesTheSourceInPlaceOfTheAtom() {
        let editor = HeadlessEditor(markdown: "ping please")
        editor.controller.insertInlineContent(mention, markdownSource: "@fred", replacing: NSRange(location: 5, length: 0))
        #expect(editor.string == "ping \u{FFFC} please")
        #expect(editor.controller.markdown() == "ping @fred please")
    }

    @Test func replacesTheGivenRangeAndPlacesTheCaretAfterTheTrailingText() {
        let editor = HeadlessEditor(markdown: "hi @fr")
        editor.controller.insertInlineContent(mention, markdownSource: "@fred", replacing: NSRange(location: 3, length: 3))
        #expect(editor.string == "hi \u{FFFC} ")
        #expect(editor.selection == NSRange(location: 5, length: 0))
    }

    @Test func undoIsASingleStep() {
        let editor = HeadlessEditor(markdown: "hi @fr")
        editor.controller.insertInlineContent(mention, markdownSource: "@fred", replacing: NSRange(location: 3, length: 3))
        editor.controller.undoManager.undo()
        #expect(editor.string == "hi @fr")
    }

    @Test func insideACodeSpanInsertsTheSourceAsText() {
        let editor = HeadlessEditor(markdown: "`a b`")
        editor.controller.insertInlineContent(mention, markdownSource: "@fred", replacing: NSRange(location: 2, length: 0), trailingText: "")
        #expect(editor.controller.textStorage.proseSourceAttachment(at: 2) == nil)
        #expect(editor.string == "a @fredb")
    }

    @Test func insideACodeBlockInsertsTheSourceAsText() {
        let editor = HeadlessEditor(markdown: "```\nx\n```")
        editor.controller.insertInlineContent(mention, markdownSource: "@fred", replacing: NSRange(location: 1, length: 0))
        #expect(editor.controller.textStorage.proseSourceAttachment(at: 1) == nil)
        #expect(editor.string == "x@fred ")
    }

    @Test func readOnlyEditorsRejectTheInsert() {
        let editor = HeadlessEditor(markdown: "hi")
        editor.controller.isEditable = false
        #expect(!editor.controller.insertInlineContent(mention, markdownSource: "@fred", replacing: NSRange(location: 2, length: 0)))
        #expect(editor.string == "hi")
    }

    #if canImport(AppKit) && os(macOS)
    @Test func chipDrawsItsSymbol() throws {
        func iconAlpha(_ symbol: String) throws -> Int {
            let size = CGSize(width: 80, height: 20)
            let image = ChipAttachment.render(label: "", symbolName: symbol, in: size)
            let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let iconSide = bitmap.pixelsHigh
            var total = 0
            for x in 0..<iconSide {
                for y in 0..<iconSide {
                    total += Int((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255)
                }
            }
            return total
        }
        #expect(try iconAlpha("person.crop.circle") > iconAlpha("not.a.symbol"))
    }
    #endif
}
