import Testing
import Foundation
import MarginaliaSyntax
@testable import MarginaliaView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct UndoTests {

    private func makeController(_ initial: String = "") throws -> EditorController {
        let c = try EditorController(initialMarkdown: initial)
        c.undoManager.groupsByEvent = false
        return c
    }

    private func serialize(_ storage: NSTextStorage) -> String {
        AttributedMarkdownSerializer().serialize(storage, dialect: .commonMark)
    }

    @Test func characterMutationUndoRestoresOriginal() throws {
        let c = try makeController("hello world\n")
        let preString = c.textStorage.string
        c.withCharacterMutation(range: NSRange(location: 5, length: 0)) {
            c.textStorage.beginEditing()
            c.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " brave")
            c.textStorage.endEditing()
        }
        #expect(c.textStorage.string == "hello brave world\n")
        c.undoManager.undo()
        #expect(c.textStorage.string == preString)
        c.undoManager.redo()
        #expect(c.textStorage.string == "hello brave world\n")
    }

    @Test func characterMutationUndoLeavesLaterEditsAlone() throws {
        let c = try makeController("hello world\n")
        c.withCharacterMutation(range: NSRange(location: 0, length: 5)) {
            c.textStorage.beginEditing()
            c.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
            c.textStorage.endEditing()
        }
        c.textStorage.beginEditing()
        c.textStorage.replaceCharacters(
            in: NSRange(location: c.textStorage.length, length: 0),
            with: "tail"
        )
        c.textStorage.endEditing()
        #expect(c.textStorage.string == "HELLO world\ntail")
        c.undoManager.undo()
        #expect(c.textStorage.string == "hello world\ntail",
                "later edit must survive earlier-op undo")
    }

    @Test func attributeMutationUndoRestoresAttributes() throws {
        let c = try makeController("hello world\n")
        c.withAttributeMutation(range: NSRange(location: 0, length: 5)) {
            _ = Operations.toggleBold(in: c.textStorage, range: NSRange(location: 0, length: 5), theme: .default)
        }
        #expect(serialize(c.textStorage) == "**hello** world\n")
        c.undoManager.undo()
        #expect(serialize(c.textStorage) == "hello world\n")
    }

    @Test func attributeMutationLeavesCharactersIntactAcrossUndo() throws {
        let c = try makeController("hello world\n")
        let preString = c.textStorage.string
        c.withAttributeMutation(range: NSRange(location: 0, length: 5)) {
            _ = Operations.toggleStrikethrough(in: c.textStorage, range: NSRange(location: 0, length: 5), theme: .default)
        }
        c.textStorage.beginEditing()
        c.textStorage.replaceCharacters(in: NSRange(location: c.textStorage.length, length: 0), with: " more")
        c.textStorage.endEditing()
        let beforeUndo = c.textStorage.string
        c.undoManager.undo()
        #expect(c.textStorage.string == beforeUndo,
                "attribute-only undo must not change character contents")
        #expect(c.textStorage.string == preString + " more")
        let attrs = c.textStorage.attributes(at: 0, effectiveRange: nil)
        #expect(attrs[.strikethroughStyle] == nil)
    }

    @Test func attributeMutationRedoRestoresMutation() throws {
        let c = try makeController("hello world\n")
        c.withAttributeMutation(range: NSRange(location: 0, length: 5)) {
            _ = Operations.toggleBold(in: c.textStorage, range: NSRange(location: 0, length: 5), theme: .default)
        }
        c.undoManager.undo()
        c.undoManager.redo()
        #expect(serialize(c.textStorage) == "**hello** world\n")
    }

    @Test func twoStackedAttributeMutationsUndoOneAtATime() throws {
        let c = try makeController("hello world\n")
        c.withAttributeMutation(range: NSRange(location: 0, length: 5)) {
            _ = Operations.toggleBold(in: c.textStorage, range: NSRange(location: 0, length: 5), theme: .default)
        }
        c.withAttributeMutation(range: NSRange(location: 6, length: 5)) {
            _ = Operations.toggleBold(in: c.textStorage, range: NSRange(location: 6, length: 5), theme: .default)
        }
        #expect(serialize(c.textStorage) == "**hello** **world**\n")
        c.undoManager.undo()
        #expect(serialize(c.textStorage) == "**hello** world\n")
        c.undoManager.undo()
        #expect(serialize(c.textStorage) == "hello world\n")
    }

    @Test func characterMutationOverEmptyRangeInsertsAndUndoes() throws {
        let c = try makeController("hello\n")
        c.withCharacterMutation(range: NSRange(location: 5, length: 0)) {
            c.textStorage.beginEditing()
            c.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
            c.textStorage.endEditing()
        }
        #expect(c.textStorage.string == "hello!\n")
        c.undoManager.undo()
        #expect(c.textStorage.string == "hello\n")
    }
}
