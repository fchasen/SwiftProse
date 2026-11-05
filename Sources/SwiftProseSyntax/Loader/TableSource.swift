import Foundation

enum TableSource {
    static func cells(ofRow line: String) -> [String] {
        let bytes = Array(trimmed(line).utf8)
        guard !bytes.isEmpty else { return [""] }
        var segments: [[UInt8]] = [[]]
        var lastPipe: Int?
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                segments[segments.count - 1].append(byte)
                segments[segments.count - 1].append(bytes[index + 1])
                index += 2
                continue
            }
            if byte == UInt8(ascii: "|") {
                lastPipe = index
                segments.append([])
            } else {
                segments[segments.count - 1].append(byte)
            }
            index += 1
        }
        if bytes.first == UInt8(ascii: "|"), segments.count > 1 {
            segments.removeFirst()
        }
        if lastPipe == bytes.count - 1, segments.count > 1 {
            segments.removeLast()
        }
        return segments.map { trimmed(String(decoding: $0, as: UTF8.self)) }
    }

    static func alignments(ofDelimiterRow line: String) -> [TableColumnAlignment]? {
        let cells = cells(ofRow: line)
        var result: [TableColumnAlignment] = []
        for cell in cells {
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":") && cell.count > 1
            let body = cell.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leading, trailing) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.none)
            }
        }
        return result.isEmpty ? nil : result
    }

    static func unescapingPipes(_ cell: String) -> String {
        guard cell.contains("\\|") else { return cell }
        var output = ""
        var iterator = cell.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                output.append(character)
                continue
            }
            guard let next = iterator.next() else {
                output.append(character)
                break
            }
            if next != "|" { output.append(character) }
            output.append(next)
        }
        return output
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }
}
