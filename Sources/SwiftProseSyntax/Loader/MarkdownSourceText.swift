import Foundation

struct MarkdownSourceText {
    let text: String
    let bytes: [UInt8]
    let lineStarts: [Int]

    init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        self.bytes = bytes
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        self.lineStarts = starts
    }

    var lineCount: Int { lineStarts.count }

    func byteRange(_ position: AttributedString.MarkdownSourcePosition) -> Range<Int>? {
        guard position.startLine >= 1, position.startLine <= lineCount,
              position.endLine >= 1, position.endLine <= lineCount
        else { return nil }
        let start = lineStarts[position.startLine - 1] + position.startColumn - 1
        let end = lineStarts[position.endLine - 1] + position.endColumn
        guard start >= 0, end <= bytes.count, start <= end else { return nil }
        return start..<end
    }

    func string(_ range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, bytes.count))
        let upper = max(lower, min(range.upperBound, bytes.count))
        return String(decoding: bytes[lower..<upper], as: UTF8.self)
    }

    func span(_ position: AttributedString.MarkdownSourcePosition?) -> String? {
        guard let position, let range = byteRange(position) else { return nil }
        return string(range)
    }

    func lineByteRange(_ line: Int) -> Range<Int> {
        guard line >= 1, line <= lineCount else { return bytes.count..<bytes.count }
        let start = lineStarts[line - 1]
        let end = line < lineCount ? lineStarts[line] - 1 : bytes.count
        return start..<max(start, end)
    }

    func lineBytes(_ line: Int) -> ArraySlice<UInt8> {
        bytes[lineByteRange(line)]
    }

    func line(_ line: Int) -> String {
        string(lineByteRange(line))
    }

    func isBlank(_ line: Int) -> Bool {
        lineBytes(line).allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    func lineIndex(containingByte offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}
