import Foundation
import SwiftTreeSitter

/// Bridges the two coordinate systems that meet inside a SwiftProseEditor editor.
///
/// `SwiftTreeSitter.Parser` defaults to `String.nativeUTF16Encoding`, so the
/// byte offsets and `Point.column` values it emits are **UTF-16 byte offsets**
/// — exactly twice the corresponding `NSRange`/UTF-16 code-unit offset.
///
/// This adapter does the trivial 2× / ÷2 conversion plus the line/column
/// walk. Callers only ever see `NSRange` (UTF-16 code units) on the Swift
/// side.
public struct TreeSitterMapping {
    public let text: String

    /// UTF-16 code-unit offsets at the start of each line. `lineStarts[0]`
    /// is always 0; `lineStarts[k]` is the offset of the first code unit of
    /// the k-th line. Computed once in init so `point(forByte:)` becomes
    /// O(log N) instead of an O(N) walk per lookup.
    private let lineStarts: [Int]

    public init(text: String) {
        self.text = text
        var starts: [Int] = [0]
        var i = 0
        for codeUnit in text.utf16 {
            i += 1
            if codeUnit == 0x0A { starts.append(i) }
        }
        self.lineStarts = starts
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
        // Binary search for the largest line start <= utf16Target.
        var lo = 0
        var hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if lineStarts[mid] <= utf16Target { lo = mid + 1 } else { hi = mid }
        }
        let rowIdx = max(0, lo - 1)
        let row = UInt32(rowIdx)
        let column = UInt32((utf16Target - lineStarts[rowIdx]) * 2)
        return Point(row: row, column: column)
    }

    /// `NSRange` (UTF-16 code units) → tree-sitter byte range.
    public func tsRange(for nsRange: NSRange) -> Range<UInt32> {
        byteOffset(forUTF16: nsRange.location)..<byteOffset(forUTF16: nsRange.location + nsRange.length)
    }
}
