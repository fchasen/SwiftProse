import Foundation
import SwiftTreeSitter

/// Bridges the two coordinate systems that meet inside a Marginalia editor.
///
/// `SwiftTreeSitter.Parser` defaults to `String.nativeUTF16Encoding`, so the
/// byte offsets and `Point.column` values it emits are **UTF-16 byte offsets**
/// — exactly twice the corresponding `NSRange`/UTF-16 code-unit offset.
///
/// This adapter does the trivial 2× / ÷2 conversion plus the line/column walk,
/// and constructs `InputEdit`s correctly for the incremental parser. Callers
/// only ever see `NSRange` (UTF-16 code units) on the Swift side.
public struct TreeSitterMapping {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    /// UTF-16 code-unit offset (an `NSRange` location) → tree-sitter byte offset.
    public func byteOffset(forUTF16 utf16: Int) -> UInt32 {
        UInt32(utf16 * 2)
    }

    /// Tree-sitter byte offset → UTF-16 code-unit offset (`NSRange`-compatible).
    public func utf16Offset(forByte byteOffset: UInt32) -> Int {
        Int(byteOffset) / 2
    }

    /// Tree-sitter byte offset → `Point` (row + UTF-16-byte column).
    public func point(forByte byteOffset: UInt32) -> Point {
        let utf16Target = Int(byteOffset) / 2
        var row: UInt32 = 0
        var lineStartUtf16 = 0
        var i = 0
        for codeUnit in text.utf16 {
            if i >= utf16Target { break }
            if codeUnit == 0x0A {
                row += 1
                lineStartUtf16 = i + 1
            }
            i += 1
        }
        let column = UInt32((utf16Target - lineStartUtf16) * 2)
        return Point(row: row, column: column)
    }

    /// `NSRange` (UTF-16 code units) → tree-sitter byte range.
    public func tsRange(for nsRange: NSRange) -> Range<UInt32> {
        byteOffset(forUTF16: nsRange.location)..<byteOffset(forUTF16: nsRange.location + nsRange.length)
    }

    /// Builds an `InputEdit` describing the replacement of `nsRange` (in this
    /// mapping's `text`) with `replacement`. Used to feed tree-sitter's
    /// incremental parser before re-parsing the new full text.
    public func makeInputEdit(replacing nsRange: NSRange, with replacement: String) -> InputEdit {
        let startByte = byteOffset(forUTF16: nsRange.location)
        let oldEndByte = byteOffset(forUTF16: nsRange.location + nsRange.length)
        let replacementUtf16 = (replacement as NSString).length
        let newEndByte = startByte + UInt32(replacementUtf16 * 2)

        let startPoint = point(forByte: startByte)
        let oldEndPoint = point(forByte: oldEndByte)

        var newRow = startPoint.row
        var newColumn = startPoint.column
        for codeUnit in replacement.utf16 {
            if codeUnit == 0x0A {
                newRow += 1
                newColumn = 0
            } else {
                newColumn += 2
            }
        }
        let newEndPoint = Point(row: newRow, column: newColumn)

        return InputEdit(
            startByte: startByte,
            oldEndByte: oldEndByte,
            newEndByte: newEndByte,
            startPoint: startPoint,
            oldEndPoint: oldEndPoint,
            newEndPoint: newEndPoint
        )
    }
}
