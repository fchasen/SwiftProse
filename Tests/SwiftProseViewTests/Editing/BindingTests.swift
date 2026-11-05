#if canImport(AppKit) && os(macOS)
import AppKit
import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Binding (macOS, .serialized)")
@MainActor
struct BindingTests {
    @Test func loadDoesNotPush() {
        let harness = EditorHarness(markdown: "hello")
        #expect(harness.pushes.isEmpty)
        harness.controller.setMarkdown("other **text**")
        #expect(harness.pushes.isEmpty)
        #expect(harness.controller.markdown() == "other **text**")
    }

    @Test func themeAndEditableToggleDoNotPush() {
        let harness = EditorHarness(markdown: "# Title\n\nbody")
        harness.controller.theme = .default(fontScale: 1.6)
        harness.controller.isEditable = false
        harness.textView.isEditable = false
        harness.controller.isEditable = true
        harness.textView.isEditable = true
        harness.spin()
        #expect(harness.pushes.isEmpty)
        let font = harness.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font == harness.controller.theme.headingFont(level: 1))
    }

    @Test func eachEditPushesOnceSynchronously() {
        let harness = EditorHarness(markdown: "hello")
        harness.select(5)
        harness.type("!")
        #expect(harness.pushes == ["hello!"])
        harness.type("?")
        #expect(harness.pushes == ["hello!", "hello!?"])
        harness.insertNewline()
        harness.type("x")
        #expect(harness.pushes.count == 3 || harness.pushes.count == 4)
        #expect(harness.pushes.last == "hello!?\n\nx")
    }

    @Test func undoPushesAndRestoresOriginalBytes() {
        let original = "* item\n\nSetext\n======"
        let harness = EditorHarness(markdown: original)
        #expect(harness.controller.markdown() == original)
        harness.select(4)
        harness.type("s")
        #expect(harness.pushes == ["- items\n\n# Setext"])
        harness.undo()
        #expect(harness.pushes.last == original)
        #expect(harness.controller.markdown() == original)
    }

    @Test func commandsPush() {
        let harness = EditorHarness(markdown: "word")
        harness.select(NSRange(location: 0, length: 4))
        harness.step { harness.controller.perform(.bold) }
        #expect(harness.pushes == ["**word**"])
        harness.undo()
        #expect(harness.pushes == ["**word**", "word"])
    }

    @Test func externalTextIsDetectedAgainstLastPushed() {
        let harness = EditorHarness(markdown: "a")
        harness.select(1)
        harness.type("b")
        #expect(harness.controller.undoManager.canUndo)
        harness.controller.applyExternalText("ab")
        #expect(harness.controller.undoManager.canUndo)
        harness.controller.applyExternalText("fresh")
        #expect(harness.string == "fresh")
        #expect(!harness.controller.undoManager.canUndo)
        #expect(harness.pushes == ["ab"])
    }

    @Test func externalSetAfterTypingWinsWithoutAPush() {
        let harness = EditorHarness(markdown: "")
        harness.type("user text")
        #expect(harness.pushes == ["user text"])
        harness.controller.applyExternalText("external\n")
        #expect(harness.string == "external")
        #expect(harness.pushes == ["user text"])
    }

    @Test func markedTextDefersPushUntilCommit() {
        let harness = EditorHarness(markdown: "a")
        harness.select(1)
        harness.setMarkedText("k")
        harness.setMarkedText("か")
        #expect(harness.pushes.isEmpty)
        harness.unmarkText()
        #expect(harness.pushes == ["aか"])
    }

    @Test func headlessControllerPushesThroughSink() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let controller = EditorController(markdown: "x", undoManager: manager)
        var pushes: [String] = []
        controller.textSink = { pushes.append($0) }
        controller.setSelection(NSRange(location: 1, length: 0))
        controller.insertMarkdown(" **y**")
        #expect(pushes == ["x **y**"])
        manager.undo()
        #expect(pushes == ["x **y**", "x"])
    }
}
#endif
