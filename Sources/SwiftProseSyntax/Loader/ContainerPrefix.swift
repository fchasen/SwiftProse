import Foundation

struct PrefixToken: Equatable {
    enum Kind: Equatable {
        case quote
        case bullet(UInt8)
        case ordered(number: Int, delimiter: UInt8)

        var isItem: Bool {
            if case .quote = self { return false }
            return true
        }

        var isOrdered: Bool {
            if case .ordered = self { return true }
            return false
        }

        var ordinal: Int? {
            if case .ordered(let number, _) = self { return number }
            return nil
        }
    }

    let kind: Kind
    let column: Int
    let contentColumn: Int
    let byteEnd: Int
}

struct LinePrefix {
    let tokens: [PrefixToken]
    let restByte: Int
    let restColumn: Int
    let rest: ArraySlice<UInt8>

    var restString: String { String(decoding: rest, as: UTF8.self) }
    var trimmedRest: String { restString.trimmingCharacters(in: .whitespaces) }
    var restIsBlank: Bool { rest.allSatisfy { $0 == 0x20 || $0 == 0x09 } }
}

enum ContainerPrefix {
    static func tokenize(_ line: ArraySlice<UInt8>) -> LinePrefix {
        let bytes = Array(line)
        var tokens: [PrefixToken] = []
        var p = 0
        var column = 0

        while true {
            var q = p
            var qColumn = column
            while q < bytes.count, bytes[q] == 0x20 || bytes[q] == 0x09 {
                qColumn = advance(qColumn, bytes[q])
                q += 1
            }
            guard q < bytes.count else { break }
            if isThematicBreak(bytes[q...]) { break }
            let byte = bytes[q]
            if byte == UInt8(ascii: ">") {
                var end = q + 1
                var endColumn = qColumn + 1
                if end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 {
                    endColumn = advance(endColumn, bytes[end])
                    end += 1
                }
                tokens.append(PrefixToken(kind: .quote, column: qColumn, contentColumn: endColumn, byteEnd: end))
                p = end
                column = endColumn
                continue
            }
            var kind: PrefixToken.Kind?
            var markerEnd = q
            if byte == UInt8(ascii: "-") || byte == UInt8(ascii: "*") || byte == UInt8(ascii: "+") {
                kind = .bullet(byte)
                markerEnd = q + 1
            } else if isDigit(byte) {
                var k = q
                while k < bytes.count, isDigit(bytes[k]), k - q < 9 {
                    k += 1
                }
                if k < bytes.count, bytes[k] == UInt8(ascii: ".") || bytes[k] == UInt8(ascii: ")"),
                   let number = Int(String(decoding: bytes[q..<k], as: UTF8.self)) {
                    kind = .ordered(number: number, delimiter: bytes[k])
                    markerEnd = k + 1
                }
            }
            guard let kind else { break }
            let followedBySpace = markerEnd >= bytes.count || bytes[markerEnd] == 0x20 || bytes[markerEnd] == 0x09
            guard followedBySpace else { break }
            let markerColumn = qColumn + (markerEnd - q)
            var end = markerEnd
            var endColumn = markerColumn
            while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 {
                endColumn = advance(endColumn, bytes[end])
                end += 1
            }
            let contentColumn: Int
            let byteEnd: Int
            if end >= bytes.count {
                contentColumn = markerColumn + 1
                byteEnd = end
            } else if endColumn - markerColumn > 4 {
                contentColumn = markerColumn + 1
                byteEnd = markerEnd + 1
            } else {
                contentColumn = endColumn
                byteEnd = end
            }
            tokens.append(PrefixToken(kind: kind, column: qColumn, contentColumn: contentColumn, byteEnd: byteEnd))
            p = byteEnd
            column = contentColumn
        }

        let restByte = min(p, bytes.count)
        let base = line.startIndex
        return LinePrefix(
            tokens: tokens,
            restByte: restByte,
            restColumn: column,
            rest: line[(base + restByte)..<line.endIndex]
        )
    }

    static func isThematicBreak<S: Collection>(_ bytes: S) -> Bool where S.Element == UInt8 {
        var marker: UInt8?
        var count = 0
        for byte in bytes {
            switch byte {
            case 0x20, 0x09:
                continue
            case UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
                if let marker, marker != byte { return false }
                marker = byte
                count += 1
            default:
                return false
            }
        }
        return count >= 3
    }

    static func isSetextUnderline(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "=" || first == "-" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    static func isLinkReferenceDefinition(_ text: String) -> Bool {
        text.range(of: #"^ {0,3}\[(?:[^\]\\]|\\.)+\]:"#, options: .regularExpression) != nil
    }

    static func emptyHeadingLevel(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.range(of: #"^#{1,6}(?:[ \t]+#*)?$"#, options: .regularExpression),
              match == trimmed.startIndex..<trimmed.endIndex
        else { return nil }
        return trimmed.prefix { $0 == "#" }.count
    }

    static func fenceOpening(_ text: String) -> (marker: Character, length: Int, info: String)? {
        let trimmed = text.drop { $0 == " " }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        return (first, run.count, info)
    }

    static func isFenceClosing(_ text: String, marker: Character, length: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= length else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    private static func advance(_ column: Int, _ byte: UInt8) -> Int {
        byte == 0x09 ? column + 4 - (column % 4) : column + 1
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
