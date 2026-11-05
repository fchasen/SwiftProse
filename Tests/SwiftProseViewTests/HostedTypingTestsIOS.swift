#if canImport(UIKit)
import XCTest
import SwiftUI
import UIKit
import SwiftProseSyntax
@testable import SwiftProseView

@MainActor
final class HostedTypingTestsIOS: XCTestCase {

    private func host(_ markdown: String) -> (EditorController, ProseUITextView, ProseTextViewIOS.Coordinator) {
        let controller = EditorController(markdown: markdown)
        let representable = ProseTextViewIOS(controller: controller, text: .constant(markdown))
        let coordinator = representable.makeCoordinator()
        let textView = representable.makeTextView(coordinator: coordinator)
        textView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        return (controller, textView, coordinator)
    }

    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func type(_ text: String, into textView: UITextView) {
        for ch in text {
            textView.insertText(String(ch))
            settle(0.005)
        }
        settle()
    }

    func testTypedCharactersLandInStorage() {
        let (controller, textView, coordinator) = host("")
        textView.selectedRange = NSRange(location: 0, length: 0)
        type("hello", into: textView)
        XCTAssertEqual(controller.textStorage.string, "hello")
        XCTAssertEqual(controller.markdown(), "hello")
        withExtendedLifetime(coordinator) {}
    }

    func testInputRulesFireForTypedText() {
        let (controller, textView, coordinator) = host("")
        textView.selectedRange = NSRange(location: 0, length: 0)
        type("# Title", into: textView)
        XCTAssertEqual(controller.textStorage.markdownBlock(at: 0)?.headingLevel, 1)
        XCTAssertEqual(controller.markdown(), "# Title")
        withExtendedLifetime(coordinator) {}
    }

    func testTypingUndoesOnTheControllersStack() {
        let (controller, textView, coordinator) = host("")
        textView.selectedRange = NSRange(location: 0, length: 0)
        type("hello", into: textView)
        XCTAssertTrue(controller.undoManager.canUndo)
        while controller.undoManager.canUndo { controller.undoManager.undo() }
        XCTAssertEqual(controller.textStorage.string, "")
        controller.undoManager.redo()
        XCTAssertFalse(controller.textStorage.string.isEmpty)
        withExtendedLifetime(coordinator) {}
    }
}
#endif
