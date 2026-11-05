import Foundation
import Synchronization

enum AlignedPiece: Equatable {
    case text(String)
    case literal(text: String, source: String)
}

enum SourceAligner {
    static func align(text: String, source: String, allowsTrailingSource: Bool = false) -> [AlignedPiece]? {
        let visible = Array(text.unicodeScalars)
        let src = Array(source.unicodeScalars)
        var pieces: [AlignedPiece] = []
        var pending = String.UnicodeScalarView()
        var i = 0
        var j = 0

        func flush() {
            guard !pending.isEmpty else { return }
            pieces.append(.text(String(pending)))
            pending = String.UnicodeScalarView()
        }

        while i < visible.count {
            guard j < src.count else { return nil }
            let scalar = src[j]
            if scalar == "\\", j + 1 < src.count, isASCIIPunctuation(src[j + 1]), visible[i] == src[j + 1] {
                flush()
                pieces.append(.literal(text: String(src[j + 1]), source: "\\" + String(src[j + 1])))
                i += 1
                j += 2
                continue
            }
            if scalar == "&", let entity = entity(in: src, at: j) {
                let decoded = Array(decodeEntity(entity.source).unicodeScalars)
                if !decoded.isEmpty,
                   decoded != Array(entity.source.unicodeScalars),
                   i + decoded.count <= visible.count,
                   Array(visible[i..<(i + decoded.count)]) == decoded {
                    flush()
                    var decodedView = String.UnicodeScalarView()
                    decodedView.append(contentsOf: decoded)
                    pieces.append(.literal(text: String(decodedView), source: entity.source))
                    i += decoded.count
                    j = entity.end
                    continue
                }
            }
            if scalar == visible[i] {
                pending.append(scalar)
                i += 1
                j += 1
                continue
            }
            if i == 0, isInlineWhitespace(scalar) {
                j += 1
                continue
            }
            return nil
        }
        guard allowsTrailingSource || src[j...].allSatisfy(isInlineWhitespace) else { return nil }
        flush()
        return pieces
    }

    static func visibleText(of pieces: [AlignedPiece]) -> String {
        pieces.map {
            switch $0 {
            case .text(let text): text
            case .literal(let text, _): text
            }
        }.joined()
    }

    static func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: true
        default: false
        }
    }

    static func isInlineWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    private static func entity(in src: [Unicode.Scalar], at start: Int) -> (source: String, end: Int)? {
        var k = start + 1
        let limit = min(src.count, start + 34)
        while k < limit, src[k] != ";" {
            k += 1
        }
        guard k < limit, src[k] == ";" else { return nil }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: src[start...k])
        let candidate = String(view)
        guard candidate.range(of: entityPattern, options: .regularExpression) != nil else { return nil }
        return (candidate, k + 1)
    }

    private static let entityPattern = "^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});$"

    static func decodeEntity(_ entity: String) -> String {
        let body = entity.dropFirst().dropLast()
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
            return String(Character(scalar))
        }
        if let cached = entityCache.withLock({ $0[entity] }) {
            return cached
        }
        let decoded = (try? AttributedString(markdown: entity)).map { String($0.characters) } ?? entity
        entityCache.withLock { $0[entity] = decoded }
        return decoded
    }

    private static let entityCache = Mutex<[String: String]>([:])
}
