import Foundation

enum SourceInlineKind: Equatable {
    case strong
    case emphasis
    case strikethrough
    case code

    var delimiter: String {
        switch self {
        case .strong: return "**"
        case .emphasis: return "*"
        case .strikethrough: return "~~"
        case .code: return "`"
        }
    }
}

struct SourceInlineSpan: Equatable {
    var kind: SourceInlineKind
    var open: NSRange
    var close: NSRange

    var outer: NSRange { NSRange(location: open.location, length: NSMaxRange(close) - open.location) }
    var inner: NSRange { NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)) }
}

struct SourceLink: Equatable {
    var outer: NSRange
    var text: NSRange
    var url: NSRange
}

enum SourceInline {
    static func spans(in ns: NSString, range: NSRange) -> [SourceInlineSpan] {
        var spans: [SourceInlineSpan] = []
        var delimiters: [Delimiter] = []
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            let c = ns.character(at: i)
            switch c {
            case 0x5C:
                if i + 1 < end, isASCIIPunctuation(ns.character(at: i + 1)) { i += 2 } else { i += 1 }
            case 0x60:
                let run = runLength(ns, at: i, end: end, char: c)
                if let close = closingBacktickRun(ns, from: i + run, end: end, length: run) {
                    spans.append(SourceInlineSpan(
                        kind: .code,
                        open: NSRange(location: i, length: run),
                        close: NSRange(location: close, length: run)
                    ))
                    i = close + run
                } else {
                    i += run
                }
            case 0x2A, 0x5F, 0x7E:
                let run = runLength(ns, at: i, end: end, char: c)
                if c != 0x7E || run <= 2 {
                    delimiters.append(Delimiter(ns, char: c, start: i, length: run, lineRange: range))
                }
                i += run
            case 0x5D where i + 1 < end && ns.character(at: i + 1) == 0x28:
                var j = i + 2
                while j < end, ns.character(at: j) != 0x29 { j += 1 }
                i = j < end ? j + 1 : i + 1
            case 0x3C:
                i = autolinkEnd(ns, at: i, end: end) ?? i + 1
            default:
                i += 1
            }
        }
        spans.append(contentsOf: processEmphasis(&delimiters))
        return spans.sorted { $0.open.location < $1.open.location }
    }

    static func links(in ns: NSString, range: NSRange) -> [SourceLink] {
        linkRegex.matches(in: ns as String, range: range).compactMap { match in
            if match.range.location > 0, ns.character(at: match.range.location - 1) == 0x21 { return nil }
            return SourceLink(outer: match.range, text: match.range(at: 1), url: match.range(at: 2))
        }
    }

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\\\[\]\n])*)\]\(\s*(<[^>\n]*>|[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\s*\)"#
    )

    private struct Delimiter {
        var char: unichar
        var start: Int
        var count: Int
        let originalLength: Int
        let canOpen: Bool
        let canClose: Bool
        var active = true

        init(_ ns: NSString, char: unichar, start: Int, length: Int, lineRange: NSRange) {
            self.char = char
            self.start = start
            self.count = length
            self.originalLength = length
            let before = SourceInline.scalar(before: start, in: ns, lower: lineRange.location)
            let after = SourceInline.scalar(at: start + length, in: ns, upper: NSMaxRange(lineRange))
            let beforeSpace = before.map(SourceInline.isWhitespace) ?? true
            let afterSpace = after.map(SourceInline.isWhitespace) ?? true
            let beforePunct = before.map(SourceInline.isPunctuation) ?? false
            let afterPunct = after.map(SourceInline.isPunctuation) ?? false
            let left = !afterSpace && (!afterPunct || beforeSpace || beforePunct)
            let right = !beforeSpace && (!beforePunct || afterSpace || afterPunct)
            if char == 0x5F {
                canOpen = left && (!right || beforePunct)
                canClose = right && (!left || afterPunct)
            } else {
                canOpen = left
                canClose = right
            }
        }
    }

    private static func processEmphasis(_ delimiters: inout [Delimiter]) -> [SourceInlineSpan] {
        var spans: [SourceInlineSpan] = []
        var closerIndex = 0
        while closerIndex < delimiters.count {
            let closer = delimiters[closerIndex]
            guard closer.active, closer.canClose, closer.count > 0 else {
                closerIndex += 1
                continue
            }
            var found: Int?
            var openerIndex = closerIndex - 1
            while openerIndex >= 0 {
                let opener = delimiters[openerIndex]
                if opener.active, opener.char == closer.char, opener.canOpen, opener.count > 0 {
                    if closer.char == 0x7E {
                        if opener.count == closer.count { found = openerIndex; break }
                    } else {
                        let sum = opener.originalLength + closer.originalLength
                        let oddMatch = (opener.canClose || closer.canOpen) && sum % 3 == 0
                            && !(opener.originalLength % 3 == 0 && closer.originalLength % 3 == 0)
                        if !oddMatch { found = openerIndex; break }
                    }
                }
                openerIndex -= 1
            }
            guard let opener = found else {
                closerIndex += 1
                continue
            }
            let used: Int
            let kind: SourceInlineKind
            if closer.char == 0x7E {
                used = closer.count
                kind = .strikethrough
            } else {
                used = delimiters[opener].count >= 2 && closer.count >= 2 ? 2 : 1
                kind = used == 2 ? .strong : .emphasis
            }
            let openRange = NSRange(location: delimiters[opener].start + delimiters[opener].count - used, length: used)
            let closeRange = NSRange(location: delimiters[closerIndex].start, length: used)
            spans.append(SourceInlineSpan(kind: kind, open: openRange, close: closeRange))
            delimiters[opener].count -= used
            delimiters[closerIndex].start += used
            delimiters[closerIndex].count -= used
            for between in (opener + 1)..<closerIndex { delimiters[between].active = false }
            if delimiters[closerIndex].count == 0 { closerIndex += 1 }
        }
        return spans
    }

    static func runLength(_ ns: NSString, at i: Int, end: Int, char: unichar) -> Int {
        var j = i
        while j < end, ns.character(at: j) == char { j += 1 }
        return j - i
    }

    static func closingBacktickRun(_ ns: NSString, from start: Int, end: Int, length: Int) -> Int? {
        var i = start
        while i < end {
            if ns.character(at: i) == 0x60 {
                let run = runLength(ns, at: i, end: end, char: 0x60)
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    static func longestBacktickRun(in text: NSString) -> Int {
        var longest = 0
        var i = 0
        while i < text.length {
            if text.character(at: i) == 0x60 {
                let run = runLength(text, at: i, end: text.length, char: 0x60)
                longest = max(longest, run)
                i += run
            } else {
                i += 1
            }
        }
        return longest
    }

    private static let autolinkRegex = try! NSRegularExpression(pattern: #"\G<[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\s]*>"#)

    private static func autolinkEnd(_ ns: NSString, at i: Int, end: Int) -> Int? {
        guard let match = autolinkRegex.firstMatch(in: ns as String, options: .anchored, range: NSRange(location: i, length: end - i)) else {
            return nil
        }
        return NSMaxRange(match.range)
    }

    static func scalar(before index: Int, in ns: NSString, lower: Int) -> UnicodeScalar? {
        guard index > lower else { return nil }
        let unit = ns.character(at: index - 1)
        if UTF16.isTrailSurrogate(unit), index - 2 >= lower {
            let lead = ns.character(at: index - 2)
            if UTF16.isLeadSurrogate(lead) {
                return UnicodeScalar(0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(unit) - 0xDC00))
            }
        }
        return UnicodeScalar(unit)
    }

    static func scalar(at index: Int, in ns: NSString, upper: Int) -> UnicodeScalar? {
        guard index < upper else { return nil }
        let unit = ns.character(at: index)
        if UTF16.isLeadSurrogate(unit), index + 1 < upper {
            let trail = ns.character(at: index + 1)
            if UTF16.isTrailSurrogate(trail) {
                return UnicodeScalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
            }
        }
        return UnicodeScalar(unit)
    }

    static func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
        scalar.properties.isWhitespace
    }

    static func isPunctuation(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    static func isASCIIPunctuation(_ c: unichar) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }
}
