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

@Suite(.serialized) struct ListEditingFlowTests {

    private func dump(_ controller: EditorController, label: String) {
        let storage = controller.textStorage
        let raw = storage.string.replacingOccurrences(of: "\u{FFFC}", with: "[FFFC]")
        print("\(label): raw='\(raw)' length=\(storage.length) markdown='\(controller.markdown())'")
        for i in 0..<storage.length {
            let attrs = storage.attributes(at: i, effectiveRange: nil)
            let charHex = String((storage.string as NSString).character(at: i), radix: 16)
            let attachKey = attrs[.attachment].map { String(describing: type(of: $0)) } ?? "nil"
            let listMarkerKey = (attrs[.marginaliaListMarker] as? Bool).map { String($0) } ?? "nil"
            let specKey = storage.blockSpec(at: i).map { "kind=\($0.kind) listLevel=\($0.listLevel)" } ?? "nil"
            print("  [\(i)] char=0x\(charHex) attachment=\(attachKey) marker=\(listMarkerKey) spec=\(specKey)")
        }
    }

    @Test func clickBulletOnEmptyEditorRendersBullet() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.unorderedList)
        dump(controller, label: "after click-bullet on empty")

        let storage = controller.textStorage
        #expect(storage.length > 0, "toggle should populate storage")
        let firstChar = (storage.string as NSString).character(at: 0)
        #expect(firstChar == 0xFFFC, "first char should be FFFC, got 0x\(String(firstChar, radix: 16))")
        let attachment = storage.attribute(.attachment, at: 0, effectiveRange: nil)
        #expect(attachment is BulletGlyphAttachment, "should have BulletGlyphAttachment, got \(String(describing: attachment))")
        let spec = storage.blockSpec(at: 0)
        #expect(spec?.isListItem == true, "should have list-item BlockSpec, got \(String(describing: spec))")
    }

    @Test func clickBulletThenTypeThenReturnCreatesSecondItem() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.unorderedList)
        dump(controller, label: "step 1 - after click-bullet")

        // Cursor should be at end of "<FFFC> " (offset 2).
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: "one")
        dump(controller, label: "step 2 - after typing 'one'")

        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        let consumed = controller.handleNewline()
        dump(controller, label: "step 3 - after Return")
        #expect(consumed, "Return should be consumed by handleNewline")
        #expect(controller.markdown() == "- one\n- \n", "should have two list items in markdown")

        let storage = controller.textStorage
        // Expect two FFFC characters in storage.
        let raw = storage.string as NSString
        var fffcCount = 0
        for i in 0..<raw.length {
            if raw.character(at: i) == 0xFFFC { fffcCount += 1 }
        }
        #expect(fffcCount == 2, "should have two bullet attachments in storage, got \(fffcCount)")
    }

    @Test func clickBulletEmptyEditorThenTypeThenReturnReturnExitsList() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.unorderedList)
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: "one")
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        #expect(controller.handleNewline()) // creates "- "
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        #expect(controller.handleNewline()) // exits list
        dump(controller, label: "after double-Return")
        #expect(controller.markdown() == "- one\n", "second Return should exit list")
    }

    @Test func tabIndentsListItem() throws {
        let controller = try EditorController(initialMarkdown: "- one\n- two\n")
        // Cursor at start of "two" body (after the second bullet's marker)
        let storage = controller.textStorage
        let ns = storage.string as NSString
        // Find the second FFFC.
        var firstFFFC = -1, secondFFFC = -1
        for i in 0..<ns.length where ns.character(at: i) == 0xFFFC {
            if firstFFFC == -1 { firstFFFC = i } else { secondFFFC = i; break }
        }
        #expect(firstFFFC >= 0 && secondFFFC > firstFFFC, "expected two bullets in storage")
        controller.testSelection = NSRange(location: secondFFFC + 2, length: 0)
        controller.perform(.indent)
        dump(controller, label: "after Tab on second item")
        // The second item should now be nested.
        #expect(controller.markdown() == "- one\n  - two\n", "second item should be indented in markdown")
        // The bullet for the nested item should be a different shape.
        let nestedSpec = controller.textStorage.blockSpec(at: ns.length - 3)
        #expect(nestedSpec?.listLevel == 1, "nested item should be list level 1")
    }

    @Test func deleteAllThenChangeDocumentThenType() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.unorderedList)
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: "first bug content")
        // User selects all, deletes.
        controller.textStorage.beginEditing()
        controller.textStorage.replaceCharacters(in: NSRange(location: 0, length: controller.textStorage.length), with: "")
        controller.textStorage.endEditing()
        // User switches to a different bug — setMarkdown is called.
        controller.setMarkdown("second bug content\n")
        #expect(controller.textStorage.string.contains("second bug content"))
        // User types more.
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: " extended")
        #expect(controller.markdown().contains("second bug content extended"))
    }

    @Test func typingAfterDeleteAllAddsContent() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.unorderedList)
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: "fred")
        // Clear all
        controller.textStorage.beginEditing()
        controller.textStorage.replaceCharacters(in: NSRange(location: 0, length: controller.textStorage.length), with: "")
        controller.textStorage.endEditing()
        #expect(controller.textStorage.length == 0)
        // Now type fresh content via the controller's insert API.
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.insert(text: "hello")
        #expect(controller.textStorage.string == "hello")
        #expect(controller.markdown() == "hello\n")
    }

    @Test func deleteAllTextFromList() throws {
        let controller = try EditorController(initialMarkdown: "")
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.perform(.unorderedList)
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: "fred")
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        _ = controller.handleNewline()
        controller.testSelection = NSRange(location: controller.textStorage.length - 1, length: 0)
        controller.insert(text: "is")
        // Now delete everything in one shot.
        controller.textStorage.beginEditing()
        controller.textStorage.replaceCharacters(in: NSRange(location: 0, length: controller.textStorage.length), with: "")
        controller.textStorage.endEditing()
        // Should not crash.
        #expect(controller.textStorage.length == 0)
    }

    @Test func backspaceAtMarkerEndDemotesListItem() throws {
        let controller = try EditorController(initialMarkdown: "- apple\n")
        // Find body start (after marker).
        let storage = controller.textStorage
        var bodyStart = -1
        storage.enumerateAttribute(.marginaliaListMarker, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? Bool) == true {
                bodyStart = range.location + range.length
                stop.pointee = true
            }
        }
        #expect(bodyStart > 0, "test setup: marker not found")
        controller.testSelection = NSRange(location: bodyStart, length: 0)
        let demoted = controller.handleBackspace()
        dump(controller, label: "after Backspace at marker-end")
        #expect(demoted, "backspace should demote")
        #expect(controller.markdown() == "apple\n", "list should be demoted to plain")
    }
}
