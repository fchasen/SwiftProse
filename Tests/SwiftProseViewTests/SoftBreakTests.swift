import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView

/// A markdown soft break is a single newline inside one block. Storage holds
/// the newline, one `NodePathBox` covers both lines, and the serializer emits
/// the single newline back. An edit that does not write a line break must
/// leave that structure alone; one that writes a break splits there and
/// nowhere else.
@Suite struct SoftBreakTests {

    @Test func typingOnTheSecondLineKeepsOneParagraph() throws {
        let controller = try EditorController(initialMarkdown: "one two\nthree four\n")
        #expect(blockCount(controller) == 1)
        type(controller, "x", before: "four")
        #expect(controller.markdown() == "one two\nthree xfour",
                "got \(String(reflecting: controller.markdown()))")
        #expect(blockCount(controller) == 1, "the paragraph split into \(blockCount(controller)) blocks")
    }

    @Test func typingOnTheSecondLineOfABlockquoteKeepsOneBlockquote() throws {
        let controller = try EditorController(initialMarkdown: "> one two\n> three four\n> five six\n")
        type(controller, "x", before: "four")
        #expect(controller.markdown() == "> one two\n> three xfour\n> five six",
                "got \(String(reflecting: controller.markdown()))")
        #expect(blockCount(controller) == 1)
    }

    /// The tail moves as one block. Splitting the second of three lines used
    /// to leave the third on the original node, which projects as three.
    @Test func writingALineBreakSplitsThereAndMovesTheWholeTail() throws {
        let controller = try EditorController(initialMarkdown: "one two\nthree four\nfive six\n")
        type(controller, "\n", before: "four")
        #expect(controller.markdown() == "one two\nthree \n\nfour\nfive six",
                "got \(String(reflecting: controller.markdown()))")
        #expect(blockCount(controller) == 2, "expected two blocks, got \(blockCount(controller))")
    }

    /// Characters typed past a block's own terminator are a new block. They
    /// inherit the platform's typing attributes, so the node they carry says
    /// nothing about where they belong.
    @Test func typingPastTheEndOpensANewParagraph() throws {
        let controller = try EditorController(initialMarkdown: "one two\n")
        type(controller, "x", at: controller.textStorage.length)
        #expect(controller.markdown() == "one two\n\nx",
                "got \(String(reflecting: controller.markdown()))")
        #expect(blockCount(controller) == 2)
    }

    @Test func aBlankLineStaysABlockBoundary() throws {
        let controller = try EditorController(initialMarkdown: "one\n\ntwo\n")
        let before = blockCount(controller)
        type(controller, "x", before: "two")
        #expect(controller.markdown() == "one\n\nxtwo",
                "got \(String(reflecting: controller.markdown()))")
        #expect(blockCount(controller) == before)
    }

    @Test func aCodeFenceStaysOneBlockWhenTypedInto() throws {
        let controller = try EditorController(initialMarkdown: "```swift\nlet a = 1\nlet b = 2\n```\n")
        type(controller, "x", before: "let b")
        #expect(controller.markdown() == "```swift\nlet a = 1\nxlet b = 2\n```",
                "got \(String(reflecting: controller.markdown()))")
        #expect(blockCount(controller) == 1)
    }

    /// Every line a paste creates is new, so each pasted block stays its own.
    @Test func aMultiLinePasteKeepsOneBlockPerPastedBlock() throws {
        let controller = try EditorController(initialMarkdown: "")
        _ = controller.dispatchPaste(
            PasteEvent(text: "Intro.\n\nOne.\n\nTwo.", selection: NSRange(location: 0, length: 0))
        )
        #expect(controller.markdown() == "Intro.\n\nOne.\n\nTwo.",
                "got \(String(reflecting: controller.markdown()))")
    }

    // MARK: - helpers

    private func blockCount(_ controller: EditorController) -> Int {
        guard case .structural(_, let kids) = controller.document.root else { return 0 }
        return kids.count
    }

    private func type(_ controller: EditorController, _ text: String, before needle: String) {
        let location = (controller.textStorage.string as NSString).range(of: needle).location
        precondition(location != NSNotFound, "no \(needle) in storage")
        type(controller, text, at: location)
    }

    /// One platform keystroke, the way the storage observer sees it.
    private func type(_ controller: EditorController, _ text: String, at location: Int) {
        let storage = controller.textStorage
        controller.testSelection = NSRange(location: location, length: 0)
        controller.nextEditHint = .typing
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: text)
        controller.testSelection = NSRange(
            location: location + (text as NSString).length,
            length: 0
        )
        storage.endEditing()
    }
}
