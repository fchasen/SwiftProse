import Testing
import Foundation
import SwiftProseSyntax
@testable import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@Suite(.serialized) struct ProseTextStorageTests {

    private func makeStorage() -> (ProseTextStorage, Box) {
        let storage = ProseTextStorage()
        let box = Box()
        storage.captureContextProvider = {
            box.contextRequests += 1
            return CaptureContext(
                selectionBefore: box.selection,
                markedTextActive: box.marked,
                hint: box.hint,
                timestamp: box.timestamp
            )
        }
        storage.editObserver = { box.records.append($0) }
        return (storage, box)
    }

    final class Box {
        var records: [EditRecord] = []
        var contextRequests = 0
        var selection = NSRange(location: 0, length: 0)
        var marked = false
        var hint: EditHint?
        var timestamp: TimeInterval = 0
    }

    @Test func replaceCharactersCapturesPreImage() {
        let (storage, box) = makeStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello")
        box.records.removeAll()

        storage.replaceCharacters(in: NSRange(location: 1, length: 3), with: "EY")

        #expect(storage.string == "hEYo")
        #expect(box.records.count == 1)
        let record = try! #require(box.records.first)
        #expect(record.origin == .platform)
        #expect(record.captures.count == 1)
        let capture = try! #require(record.captures.first)
        #expect(capture.kind == .characters(insertedLength: 2))
        #expect(capture.range == NSRange(location: 1, length: 3))
        #expect(capture.preImage.string == "ell")
    }

    @Test func attributedReplaceCapturesOnce() {
        let (storage, box) = makeStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abc")
        box.records.removeAll()

        let replacement = NSAttributedString(
            string: "XY",
            attributes: [.proseListMarker: true]
        )
        storage.replaceCharacters(in: NSRange(location: 1, length: 1), with: replacement)

        #expect(box.records.count == 1)
        #expect(box.records[0].captures.count == 1,
                "an attributed replacement must not decompose into string + per-run setAttributes")
        #expect(box.records[0].captures[0].preImage.string == "b")
        #expect(storage.string == "aXYc")
    }

    @Test func setAttributesCapturesRunPreImage() {
        let (storage, box) = makeStorage()
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: NSAttributedString(string: "abc", attributes: [.proseListMarker: true])
        )
        box.records.removeAll()

        storage.setAttributes([:], range: NSRange(location: 0, length: 3))

        #expect(box.records.count == 1)
        let capture = try! #require(box.records[0].captures.first)
        #expect(capture.kind == .attributes)
        #expect(capture.preImage.attribute(.proseListMarker, at: 0, effectiveRange: nil) as? Bool == true)
    }

    @Test func transactionOriginSkipsCapture() {
        let (storage, box) = makeStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abc")
        box.records.removeAll()

        storage.withOrigin(.transaction) {
            storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Z")
        }

        #expect(box.records.count == 1)
        #expect(box.records[0].origin == .transaction)
        #expect(box.records[0].captures.isEmpty)
    }

    @Test func capturingNormalizeScopeStillCaptures() {
        let (storage, box) = makeStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abc")
        box.records.removeAll()

        storage.withOrigin(.normalize, capturing: true) {
            storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Z")
        }

        #expect(box.records[0].origin == .normalize)
        #expect(box.records[0].captures.count == 1)
        #expect(box.records[0].captures[0].preImage.string == "a")
    }

    @Test func nestedOriginRestoresOuter() {
        let (storage, _) = makeStorage()
        #expect(storage.currentOrigin == .platform)
        storage.withOrigin(.transaction) {
            #expect(storage.currentOrigin == .transaction)
            storage.withOrigin(.normalize) {
                #expect(storage.currentOrigin == .normalize)
                // The record is owned by the outermost bracket.
                #expect(storage.recordOrigin == .transaction)
            }
            #expect(storage.currentOrigin == .transaction)
        }
        #expect(storage.currentOrigin == .platform)
    }

    @Test func bracketedEditsYieldOneRecordWithAllCaptures() {
        let (storage, box) = makeStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abcdef")
        box.records.removeAll()

        // A drag-move: delete then insert, inside one bracket.
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 4, length: 2), with: "")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ef")
        storage.endEditing()

        #expect(storage.string == "efabcd")
        #expect(box.records.count == 1, "one bracket, one record")
        #expect(box.records[0].captures.count == 2)
        #expect(box.records[0].captures[0].preImage.string == "ef")
        #expect(box.records[0].captures[1].preImage.string == "")
    }

    @Test func contextIsRequestedOncePerGroup() {
        let (storage, box) = makeStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "abcdef")
        box.contextRequests = 0
        box.selection = NSRange(location: 3, length: 0)

        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 4, length: 2), with: "")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ef")
        storage.endEditing()

        #expect(box.contextRequests == 1,
                "a drag-move produces two captures but one context")
        #expect(box.records.last?.context?.selectionBefore == NSRange(location: 3, length: 0))
    }

    @Test func attributeFixingInsideProcessEditingDoesNotCapture() {
        let (storage, box) = makeStorage()
        // A stray .attachment on a non-FFFC character is exactly what
        // `fixAttributes` strips inside `processEditing`.
        let attachment = NSTextAttachment()
        let s = NSMutableAttributedString(string: "abc")
        s.addAttribute(.attachment, value: attachment, range: NSRange(location: 0, length: 3))
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: s)

        #expect(box.records.count == 1)
        #expect(box.records[0].captures.count == 1,
                "attribute fixing must not append captures of its own")
    }

    @Test func preImageDoesNotAliasTheBackingStore() {
        let (storage, box) = makeStorage()
        let long = String(repeating: "abcdefghij", count: 500)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: long)
        box.records.removeAll()

        // Replace a big chunk; the captured pre-image must be a snapshot,
        // not a proxy that follows the buffer.
        storage.replaceCharacters(in: NSRange(location: 100, length: 3000), with: "Z")
        let capture = try! #require(box.records.first?.captures.first)
        #expect(capture.preImage.length == 3000)
        #expect(capture.preImage.string.hasPrefix("abcdefghij"))
        #expect(storage.length == long.utf16.count - 2999)

        // Mutate again — the earlier pre-image is still the earlier content.
        storage.replaceCharacters(in: NSRange(location: 0, length: 50), with: "")
        #expect(capture.preImage.length == 3000)
        #expect(capture.preImage.string.hasPrefix("abcdefghij"))
    }

    @Test func stringIsStableBetweenEdits() {
        let (storage, _) = makeStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello world")
        let a = storage.string
        let b = storage.string
        #expect(a == b)
        #expect(a == "hello world")
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: ",")
        #expect(storage.string == "hello, world")
        #expect((storage.string as NSString).length == storage.length)
    }

    @Test func recordCarriesEditedRangeAndDelta() {
        let (storage, box) = makeStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello")
        box.records.removeAll()
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!!")
        let record = try! #require(box.records.first)
        #expect(record.changeInLength == 2)
        #expect(record.editedRange == NSRange(location: 5, length: 2))
        #expect(record.isCharacterEdit)
    }

    // MARK: - through the controller

    @Test func controllerTransactionsRecordTransactionOrigin() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var origins: [EditOrigin] = []
        controller.proseStorage.editObserver = { origins.append($0.origin) }
        controller.testSelection = NSRange(location: 5, length: 0)
        _ = controller.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 5, length: 0),
                         with: NSAttributedString(string: "!"))
        ]))
        #expect(!origins.isEmpty)
        #expect(origins.allSatisfy { $0 == .transaction || $0 == .normalize },
                "got \(origins)")
    }

    @Test func controllerPlatformTypingCapturesAnInverse() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var records: [EditRecord] = []
        controller.proseStorage.editObserver = { records.append($0) }
        controller.testSelection = NSRange(location: 5, length: 0)

        let storage = controller.textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        storage.endEditing()

        let platform = records.filter { $0.origin == .platform && $0.isCharacterEdit }
        #expect(platform.count == 1)
        #expect(platform[0].captures.count == 1)
        #expect(platform[0].captures[0].preImage.length == 0)
        #expect(platform[0].captures[0].range == NSRange(location: 5, length: 0))
    }

    @Test func multiStepTransactionProducesOneCharacterRecord() throws {
        let controller = try EditorController(initialMarkdown: "hello\n")
        var records: [EditRecord] = []
        controller.testSelection = NSRange(location: 0, length: 0)
        controller.proseStorage.editObserver = { records.append($0) }
        _ = controller.apply(Transaction(steps: [
            .replaceText(range: NSRange(location: 5, length: 0),
                         with: NSAttributedString(string: "A")),
            .replaceText(range: NSRange(location: 0, length: 0),
                         with: NSAttributedString(string: "B"))
        ]))
        let characterRecords = records.filter { $0.origin == .transaction && $0.isCharacterEdit }
        #expect(characterRecords.count == 1,
                "one bracket for the whole transaction, got \(records.map { ($0.origin, $0.isCharacterEdit) })")
        #expect(characterRecords[0].changeInLength == 2)
    }
}
