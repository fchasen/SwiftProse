import Foundation
import Testing
@testable import SwiftProseSyntax
@testable import SwiftProseRendering
@testable import SwiftProseView
import SwiftProseTestSupport

@Suite("Document change")
struct DocumentChangeTests {
    @Test func rangeAfterAnEditShiftsByTheChangeInLength() {
        let range = NSRange(location: 10, length: 2)
        #expect(range.shifted(byEdit: NSRange(location: 2, length: 3), changeInLength: 3) == NSRange(location: 13, length: 2))
        #expect(range.shifted(byEdit: NSRange(location: 2, length: 0), changeInLength: -4) == NSRange(location: 6, length: 2))
    }

    @Test func rangeBeforeAnEditKeepsItsPosition() {
        let range = NSRange(location: 0, length: 2)
        #expect(range.shifted(byEdit: NSRange(location: 5, length: 1), changeInLength: 1) == range)
    }

    @Test func rangeInsideReplacedTextCollapsesOntoTheEdit() {
        let range = NSRange(location: 5, length: 2)
        #expect(range.shifted(byEdit: NSRange(location: 3, length: 0), changeInLength: -5) == NSRange(location: 3, length: 0))
        let overlapping = NSRange(location: 4, length: 4)
        #expect(overlapping.shifted(byEdit: NSRange(location: 6, length: 1), changeInLength: -3) == NSRange(location: 4, length: 3))
    }

    @Test func mergeCoversBothEdits() {
        let earlier = NSRange(location: 20, length: 1)
        #expect(earlier.merged(withEdit: NSRange(location: 2, length: 3), changeInLength: 3) == NSRange(location: 2, length: 22))
    }

    @MainActor
    private final class EditingPlugin: EditorPlugin {
        let key = AnyPluginKey(name: "test.editing")
        func documentDidChange(_ change: DocumentChange, controller: EditorController) {
            guard change.origin == .user else { return }
            controller.replaceText(in: NSRange(location: controller.textStorage.length, length: 0), with: "!")
        }
    }

    @MainActor
    private final class RecordingPlugin: EditorPlugin {
        let key = AnyPluginKey(name: "test.recording")
        var origins: [DocumentChange.Origin] = []
        func documentDidChange(_ change: DocumentChange, controller: EditorController) {
            origins.append(change.origin)
        }
    }

    @Test @MainActor func editsMadeDuringFanoutReachLaterListenersInOrder() {
        let editor = HeadlessEditor(markdown: "a")
        let recorder = RecordingPlugin()
        editor.controller.register(plugin: EditingPlugin())
        editor.controller.register(plugin: recorder)
        var observed: [DocumentChange.Origin] = []
        editor.controller.addOnDocumentChange { observed.append($0.origin) }
        editor.type("b")
        #expect(editor.string == "ab!")
        #expect(recorder.origins == [.user, .command])
        #expect(observed == [.user, .command])
    }

    @Test @MainActor func coalescedChangeCoversEditsMadeOutOfOrder() throws {
        let controller = EditorController(markdown: "0123456789abcdefghij0123456789")
        var changes: [DocumentChange] = []
        controller.addOnDocumentChange { changes.append($0) }
        controller.textStorage.replaceCharacters(in: NSRange(location: 20, length: 0), with: "X")
        controller.textStorage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "YYY")
        controller.flushDocumentChanges()
        let change = try #require(changes.last)
        #expect(change.changeInLength == 4)
        #expect(NSLocationInRange(2, change.editedRange))
        #expect(NSLocationInRange(23, change.editedRange))
    }
}

@Suite("Controller load bytes")
struct ControllerLoadBytesTests {
    @Test @MainActor func controllerReturnsOriginalBytesWhenUnchanged() {
        let controller = EditorController(markdown: "hello\n\n")
        #expect(controller.markdown() == "hello\n\n")
    }
}
