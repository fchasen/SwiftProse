import Testing
import Foundation
import SwiftTreeSitter
@testable import MarginaliaSyntax

@Suite(.serialized) struct TreeSitterMappingTests {

    // MARK: - byte ↔ utf16 (UTF-16 byte = 2 × code unit)

    @Test func byteOffsetASCII() {
        let m = TreeSitterMapping(text: "hello")
        #expect(m.byteOffset(forUTF16: 0) == 0)
        #expect(m.byteOffset(forUTF16: 3) == 6)
        #expect(m.byteOffset(forUTF16: 5) == 10)
    }

    @Test func byteOffsetEmoji() {
        let m = TreeSitterMapping(text: "a🚀b")
        // 🚀 is 2 UTF-16 code units → 4 UTF-16 bytes
        #expect(m.byteOffset(forUTF16: 0) == 0)
        #expect(m.byteOffset(forUTF16: 1) == 2)
        #expect(m.byteOffset(forUTF16: 3) == 6)
        #expect(m.byteOffset(forUTF16: 4) == 8)
    }

    @Test func byteOffsetCJK() {
        let m = TreeSitterMapping(text: "中文")
        // 中, 文 each = 1 UTF-16 code unit → 2 UTF-16 bytes
        #expect(m.byteOffset(forUTF16: 0) == 0)
        #expect(m.byteOffset(forUTF16: 1) == 2)
        #expect(m.byteOffset(forUTF16: 2) == 4)
    }

    @Test func utf16OffsetForByte() {
        let m = TreeSitterMapping(text: "a🚀b")
        #expect(m.utf16Offset(forByte: 0) == 0)
        #expect(m.utf16Offset(forByte: 2) == 1)
        #expect(m.utf16Offset(forByte: 6) == 3)
        #expect(m.utf16Offset(forByte: 8) == 4)
    }

    @Test func roundTripASCIIAndEmoji() {
        let m = TreeSitterMapping(text: "hello 🚀 world\nfoo bar")
        var utf16Off = 0
        for scalar in m.text.unicodeScalars {
            let byte = m.byteOffset(forUTF16: utf16Off)
            #expect(m.utf16Offset(forByte: byte) == utf16Off)
            utf16Off += scalar.utf16.count
        }
        let endByte = m.byteOffset(forUTF16: utf16Off)
        #expect(m.utf16Offset(forByte: endByte) == utf16Off)
    }

    // MARK: - points

    @Test func pointSingleLine() {
        let m = TreeSitterMapping(text: "hello")
        #expect(m.point(forByte: 0) == Point(row: 0, column: 0))
        #expect(m.point(forByte: 6) == Point(row: 0, column: 6))
        #expect(m.point(forByte: 10) == Point(row: 0, column: 10))
    }

    @Test func pointAcrossNewlines() {
        let m = TreeSitterMapping(text: "hello\nworld")
        // \n is at utf16=5 → byte 10
        #expect(m.point(forByte: 10) == Point(row: 0, column: 10))
        #expect(m.point(forByte: 12) == Point(row: 1, column: 0))
        #expect(m.point(forByte: 22) == Point(row: 1, column: 10))
    }

    @Test func pointInMultilineEmoji() {
        // "🚀\n🚀": 🚀 = 2 utf16 = 4 bytes; \n = 1 utf16 = 2 bytes
        let m = TreeSitterMapping(text: "🚀\n🚀")
        #expect(m.point(forByte: 0) == Point(row: 0, column: 0))
        #expect(m.point(forByte: 4) == Point(row: 0, column: 4))   // before \n
        #expect(m.point(forByte: 6) == Point(row: 1, column: 0))   // after \n
        #expect(m.point(forByte: 10) == Point(row: 1, column: 4))
    }

    // MARK: - tsRange

    @Test func tsRangeCoversEmoji() {
        let m = TreeSitterMapping(text: "a🚀b")
        let nsRange = NSRange(location: 1, length: 2)
        let r = m.tsRange(for: nsRange)
        #expect(r.lowerBound == 2)
        #expect(r.upperBound == 6)
    }

    // MARK: - InputEdit

    @Test func inputEditAppendASCII() {
        let m = TreeSitterMapping(text: "hello")
        let edit = m.makeInputEdit(replacing: NSRange(location: 5, length: 0), with: " world")
        #expect(edit.startByte == 10)
        #expect(edit.oldEndByte == 10)
        #expect(edit.newEndByte == 22)
        #expect(edit.startPoint == Point(row: 0, column: 10))
        #expect(edit.oldEndPoint == Point(row: 0, column: 10))
        #expect(edit.newEndPoint == Point(row: 0, column: 22))
    }

    @Test func inputEditReplaceASCII() {
        let m = TreeSitterMapping(text: "hello world")
        let edit = m.makeInputEdit(replacing: NSRange(location: 6, length: 5), with: "Earth")
        #expect(edit.startByte == 12)
        #expect(edit.oldEndByte == 22)
        #expect(edit.newEndByte == 22)
        #expect(edit.newEndPoint == Point(row: 0, column: 22))
    }

    @Test func inputEditInsertNewline() {
        let m = TreeSitterMapping(text: "hello")
        let edit = m.makeInputEdit(replacing: NSRange(location: 5, length: 0), with: "\nworld")
        #expect(edit.newEndPoint == Point(row: 1, column: 10))
    }

    @Test func inputEditDeletion() {
        let m = TreeSitterMapping(text: "hello world")
        let edit = m.makeInputEdit(replacing: NSRange(location: 5, length: 6), with: "")
        #expect(edit.startByte == 10)
        #expect(edit.oldEndByte == 22)
        #expect(edit.newEndByte == 10)
        #expect(edit.newEndPoint == Point(row: 0, column: 10))
    }

    @Test func inputEditWithEmojiInReplacement() {
        let m = TreeSitterMapping(text: "ab")
        let edit = m.makeInputEdit(replacing: NSRange(location: 1, length: 0), with: "🚀")
        #expect(edit.startByte == 2)
        #expect(edit.oldEndByte == 2)
        #expect(edit.newEndByte == 6)
        #expect(edit.newEndPoint == Point(row: 0, column: 6))
    }

    @Test func inputEditMultiLineEdit() {
        let m = TreeSitterMapping(text: "first\nsecond")
        let edit = m.makeInputEdit(replacing: NSRange(location: 6, length: 6), with: "new\nthird")
        #expect(edit.startPoint == Point(row: 1, column: 0))
        #expect(edit.oldEndPoint == Point(row: 1, column: 12))
        #expect(edit.newEndPoint == Point(row: 2, column: 10))
    }
}
