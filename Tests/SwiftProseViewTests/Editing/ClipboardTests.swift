import Foundation
import Testing
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite(.serialized)
@MainActor
struct ClipboardTests {
    private func controller(_ markdown: String, caret: Int) -> EditorController {
        let editor = HeadlessEditor(markdown: markdown)
        editor.select(caret)
        return editor.controller
    }

    @Test func defaultBranchInsertsPlainText() {
        let controller = controller("hi", caret: 2)
        let event = PasteEvent(text: " there", selection: NSRange(location: 2, length: 0))
        #expect(controller.dispatchPaste(event))
        #expect(controller.markdown() == "hi there")
    }

    @Test func defaultBranchThemesPlainPasteIntoEmptyStorage() throws {
        let theme = ProseTheme.default
        let controller = controller("", caret: 0)
        let event = PasteEvent(text: "Bug 2043020 - header", selection: NSRange(location: 0, length: 0))
        #expect(controller.dispatchPaste(event))
        let attrs = controller.textStorage.attributes(at: 0, effectiveRange: nil)
        let font = try #require(attrs[.font] as? PlatformFont)
        #expect(abs(font.pointSize - theme.bodyFont.pointSize) < 0.1)
        #expect(attrs[.foregroundColor] != nil)
        #expect(attrs[.paragraphStyle] != nil)
        #expect(controller.textStorage.markdownBlock(at: 0) == .paragraph)
    }

    @Test(.disabled("leading blank lines in a plain paste are dropped, fusing the first pasted paragraph into the caret's paragraph"))
    func multiBlockSplitOnBlankLineRuns() {
        let controller = controller("start", caret: 5)
        let event = PasteEvent(text: "\n\nfirst\n\nsecond", selection: NSRange(location: 5, length: 0))
        _ = controller.dispatchPaste(event)
        #expect(controller.markdown() == "start\n\nfirst\n\nsecond")
    }

    @Test func plainBranchCollapsesMultiBlankRuns() {
        let controller = controller("", caret: 0)
        _ = controller.dispatchPaste(PasteEvent(text: "a\n\n\n\nb", selection: NSRange(location: 0, length: 0)))
        #expect(controller.markdown() == "a\n\nb")
    }

    @Test func plainTextRouteSkipsHtmlEvenWhenPresent() {
        let controller = controller("x", caret: 1)
        let event = PasteEvent(text: "y", html: "<b>y</b>", plainText: true, selection: NSRange(location: 1, length: 0))
        _ = controller.dispatchPaste(event)
        #expect(controller.markdown() == "xy")
    }

    @Test func dictationLandsAsOneUndoStep() {
        let controller = controller("hi", caret: 2)
        let event = PasteEvent(
            text: " hello\n\nworld",
            plainText: true,
            source: .dictation,
            selection: NSRange(location: 2, length: 0)
        )
        _ = controller.dispatchPaste(event)
        #expect(controller.markdown() == "hi hello\n\nworld")
        #expect(controller.undoManager.canUndo)
        controller.undoManager.undo()
        #expect(controller.markdown() == "hi")
    }

    @Test func emptyTextEventIsNoOp() {
        let controller = controller("abc", caret: 3)
        let event = PasteEvent(text: "", selection: NSRange(location: 3, length: 0))
        #expect(controller.dispatchPaste(event) == false)
        #expect(controller.markdown() == "abc")
    }

    @Test func nilTextEventIsNoOp() {
        let controller = controller("abc", caret: 3)
        let event = PasteEvent(text: nil, selection: NSRange(location: 3, length: 0))
        #expect(controller.dispatchPaste(event) == false)
        #expect(controller.markdown() == "abc")
    }

    @Test func readOnlyControllerSkipsDefaultInsertion() {
        let controller = controller("abc", caret: 3)
        controller.isEditable = false
        let event = PasteEvent(text: " more", selection: NSRange(location: 3, length: 0))
        #expect(controller.dispatchPaste(event) == false)
        #expect(controller.markdown() == "abc")
    }

    @Test func crlfNormalization() {
        let controller = controller("", caret: 0)
        let event = PasteEvent(text: "one\r\ntwo\rthree", selection: NSRange(location: 0, length: 0))
        _ = controller.dispatchPaste(event)
        let md = controller.markdown()
        #expect(!md.contains("\r"))
        #expect(md.contains("one"))
        #expect(md.contains("two"))
        #expect(md.contains("three"))
    }
}

#if canImport(AppKit) && os(macOS)
@MainActor
@Suite(.serialized)
struct MacClipboardPasteboardTests {
    @Test func rtfOnlyTextKitPayloadFallsBackToPlainText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let attributed = NSAttributedString(
            string: "Bug 2043020 - header",
            attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.black
            ]
        )
        let data = try #require(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:]
        ))
        pasteboard.setData(data, forType: .rtf)

        let contents = Clipboard.read(from: pasteboard)
        #expect(contents.text == "Bug 2043020 - header")
    }
}

@MainActor
@Suite(.serialized)
struct MacDictationHeuristicTests {
    @Test func multiCharWithNewlineRoutesToPaste() {
        let harness = EditorHarness(markdown: "")
        harness.type("hello\n\nworld")
        #expect(harness.markdown == "hello\n\nworld")
    }

    @Test func singleCharStaysOnDefaultPath() {
        let harness = EditorHarness(markdown: "")
        #expect(harness.controller.hostShouldChangeText(in: NSRange(location: 0, length: 0), replacement: "a"))
    }

    @Test func multiCharWithoutWhitespaceStaysOnDefaultPath() {
        let harness = EditorHarness(markdown: "")
        #expect(harness.controller.hostShouldChangeText(in: NSRange(location: 0, length: 0), replacement: "東京"))
        harness.type("東京")
        #expect(harness.string == "東京")
    }
}
#endif
