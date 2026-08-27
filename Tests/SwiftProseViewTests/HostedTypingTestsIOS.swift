import XCTest
import SwiftUI
import SwiftProseSyntax
@testable import SwiftProseView

#if canImport(UIKit)
import UIKit

/// Types through `UITextView.insertText` — UIKit's own input path — so the
/// view's undo integration is exercised the way a keyboard would. XCTest
/// for the same reason as the macOS suite: it runs serially, before the
/// parallel Swift Testing phase.
@MainActor
final class HostedTypingTestsIOS: XCTestCase {

    /// Mirrors `ProseTextViewIOS.makeUIView`.
    private func host(_ markdown: String) throws -> (EditorController, ProseUITextView, ProseTextViewIOS.Coordinator) {
        let controller = try EditorController(initialMarkdown: markdown, theme: .default)
        let representable = ProseTextViewIOS(controller: controller, text: .constant(markdown))
        let coordinator = representable.makeCoordinator()
        let textView = ProseUITextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), textContainer: controller.textContainer)
        textView.proseController = controller
        textView.delegate = coordinator
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.isEditable = true
        coordinator.textView = textView
        controller.hostTextView = textView
        return (controller, textView, coordinator)
    }

    private func type(_ text: String, into textView: UITextView) async throws {
        for ch in text { textView.insertText(String(ch)) }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testTypedCharactersLandInStorage() async throws {
        let (controller, textView, _) = try host("")
        textView.selectedRange = NSRange(location: 0, length: 0)
        try await type("hello", into: textView)
        XCTAssertEqual(controller.textStorage.string, "hello")
        XCTAssertEqual(controller.markdown(), "hello")
    }

    func testTypedCharactersClassifyAsTyping() async throws {
        let (controller, textView, _) = try host("")
        var classes: [EditorController.EditClass] = []
        controller.classificationProbe = { classes.append($0) }
        textView.selectedRange = NSRange(location: 0, length: 0)
        try await type("ab", into: textView)
        XCTAssertEqual(classes, [.typing, .typing])
    }

    func testTypingIsOneUndoUnitOnTheControllersStack() async throws {
        let (controller, textView, _) = try host("")
        textView.selectedRange = NSRange(location: 0, length: 0)
        try await type("hello", into: textView)
        XCTAssertTrue(controller.undoManager.canUndo)
        controller.undoManager.undo()
        XCTAssertEqual(controller.textStorage.string, "")
        XCTAssertFalse(controller.undoManager.canUndo)
        controller.undoManager.redo()
        XCTAssertEqual(controller.textStorage.string, "hello")
    }
}
#endif
