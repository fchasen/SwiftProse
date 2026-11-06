import Testing
import Foundation
import SwiftTreeSitter
import SwiftProseTreeSitter

@Suite struct TreeSitterMappingTests {
    @Test func byteOffsetASCII() {
        let m = TreeSitterMapping(text: "hello")
        #expect(m.byteOffset(forUTF16: 0) == 0)
        #expect(m.byteOffset(forUTF16: 3) == 6)
        #expect(m.byteOffset(forUTF16: 5) == 10)
    }

    @Test func byteOffsetEmoji() {
        let m = TreeSitterMapping(text: "a🚀b")
        #expect(m.byteOffset(forUTF16: 0) == 0)
        #expect(m.byteOffset(forUTF16: 1) == 2)
        #expect(m.byteOffset(forUTF16: 3) == 6)
        #expect(m.byteOffset(forUTF16: 4) == 8)
    }

    @Test func byteOffsetCJK() {
        let m = TreeSitterMapping(text: "中文")
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

    @Test func pointSingleLine() {
        let m = TreeSitterMapping(text: "hello")
        #expect(m.point(forByte: 0) == Point(row: 0, column: 0))
        #expect(m.point(forByte: 6) == Point(row: 0, column: 6))
        #expect(m.point(forByte: 10) == Point(row: 0, column: 10))
    }

    @Test func pointAcrossNewlines() {
        let m = TreeSitterMapping(text: "hello\nworld")
        #expect(m.point(forByte: 10) == Point(row: 0, column: 10))
        #expect(m.point(forByte: 12) == Point(row: 1, column: 0))
        #expect(m.point(forByte: 22) == Point(row: 1, column: 10))
    }

    @Test func pointInMultilineEmoji() {
        let m = TreeSitterMapping(text: "🚀\n🚀")
        #expect(m.point(forByte: 0) == Point(row: 0, column: 0))
        #expect(m.point(forByte: 4) == Point(row: 0, column: 4))
        #expect(m.point(forByte: 6) == Point(row: 1, column: 0))
        #expect(m.point(forByte: 10) == Point(row: 1, column: 4))
    }

    @Test func tsRangeCoversEmoji() {
        let m = TreeSitterMapping(text: "a🚀b")
        let nsRange = NSRange(location: 1, length: 2)
        let r = m.tsRange(for: nsRange)
        #expect(r.lowerBound == 2)
        #expect(r.upperBound == 6)
    }
}
