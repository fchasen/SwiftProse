import Foundation

package struct SourceInlineToken: Equatable {
    package enum Kind: Int, Equatable {
        case linkText
        case strong
        case emphasis
        case strikethrough
        case code
        case url
        case html
        case syntax
    }

    package var kind: Kind
    package var range: NSRange
}

package struct SourceInlineScan: Equatable {
    package var tokens: [SourceInlineToken]
    package var openCodeSpan: Int

    static let empty = SourceInlineScan(tokens: [], openCodeSpan: 0)

    package init(tokens: [SourceInlineToken], openCodeSpan: Int) {
        self.tokens = tokens
        self.openCodeSpan = openCodeSpan
    }
}

package struct SourceInlineScanner {
    let text: NSString
    let start: Int
    let end: Int
    let stylesPipes: Bool
    let openingCodeSpan: Int
    package let laterRuns: UInt64

    private var protected: [Bool]
    private(set) var tokens: [SourceInlineToken] = []
    private(set) var openCodeSpan = 0

    init(text: NSString, range: NSRange, stylesPipes: Bool, openingCodeSpan: Int = 0, laterRuns: UInt64 = 0) {
        self.text = text
        self.start = range.location
        self.end = NSMaxRange(range)
        self.stylesPipes = stylesPipes
        self.openingCodeSpan = openingCodeSpan
        self.laterRuns = laterRuns
        self.protected = Array(repeating: false, count: text.length)
    }

    static func scan(_ text: NSString, range: NSRange, stylesPipes: Bool = false) -> [SourceInlineToken] {
        scanLine(text, range: range, stylesPipes: stylesPipes).tokens
    }

    package static func scanLine(
        _ text: NSString,
        range: NSRange,
        stylesPipes: Bool = false,
        openingCodeSpan: Int = 0,
        laterRuns: UInt64 = 0
    ) -> SourceInlineScan {
        guard range.length > 0 else {
            return SourceInlineScan(tokens: [], openCodeSpan: openingCodeSpan)
        }
        var scanner = SourceInlineScanner(
            text: text,
            range: range,
            stylesPipes: stylesPipes,
            openingCodeSpan: openingCodeSpan,
            laterRuns: laterRuns
        )
        scanner.scanEscapesAndCodeSpans()
        scanner.scanAngleConstructs()
        scanner.scanLinks()
        scanner.scanBareURLs()
        scanner.scanDelimiters()
        if stylesPipes { scanner.scanPipes() }
        return SourceInlineScan(
            tokens: scanner.tokens.sorted { $0.kind.rawValue < $1.kind.rawValue },
            openCodeSpan: scanner.openCodeSpan
        )
    }

    static func runMask(_ length: Int) -> UInt64 {
        length >= 1 && length <= 64 ? UInt64(1) << UInt64(length - 1) : 0
    }

    package static func backtickRuns(in text: NSString, range: NSRange) -> UInt64 {
        var mask: UInt64 = 0
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            guard text.character(at: i) == 0x60 else {
                i += 1
                continue
            }
            var runEnd = i
            while runEnd < end, text.character(at: runEnd) == 0x60 { runEnd += 1 }
            mask |= runMask(runEnd - i)
            i = runEnd
        }
        return mask
    }

    private func closingRun(of length: Int, from location: Int) -> Int? {
        var probe = location
        while probe < end {
            guard char(probe) == 0x60 else {
                probe += 1
                continue
            }
            var closeEnd = probe
            while closeEnd < end, char(closeEnd) == 0x60 { closeEnd += 1 }
            if closeEnd - probe == length { return probe }
            probe = closeEnd
        }
        return nil
    }

    private func char(_ i: Int) -> unichar { text.character(at: i) }

    private mutating func add(_ kind: SourceInlineToken.Kind, _ location: Int, _ length: Int) {
        guard length > 0 else { return }
        tokens.append(SourceInlineToken(kind: kind, range: NSRange(location: location, length: length)))
    }

    private mutating func protect(_ location: Int, _ length: Int) {
        for i in location..<(location + length) where i < protected.count { protected[i] = true }
    }

    static func isASCIIPunctuation(_ c: unichar) -> Bool {
        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }

    private mutating func scanEscapesAndCodeSpans() {
        var i = start
        if openingCodeSpan > 0 {
            guard let close = closingRun(of: openingCodeSpan, from: start) else {
                add(.code, start, end - start)
                protect(start, end - start)
                openCodeSpan = openingCodeSpan
                return
            }
            add(.code, start, close + openingCodeSpan - start)
            add(.syntax, close, openingCodeSpan)
            protect(start, close + openingCodeSpan - start)
            i = close + openingCodeSpan
        }
        while i < end {
            let c = char(i)
            if c == 0x5C, i + 1 < end, Self.isASCIIPunctuation(char(i + 1)) {
                add(.syntax, i, 1)
                protect(i, 2)
                i += 2
                continue
            }
            guard c == 0x60 else {
                i += 1
                continue
            }
            var runEnd = i
            while runEnd < end, char(runEnd) == 0x60 { runEnd += 1 }
            let length = runEnd - i
            guard let close = closingRun(of: length, from: runEnd) else {
                if laterRuns & Self.runMask(length) != 0 {
                    add(.code, i, end - i)
                    add(.syntax, i, length)
                    protect(i, end - i)
                    openCodeSpan = length
                    return
                }
                i = runEnd
                continue
            }
            add(.code, i, close + length - i)
            add(.syntax, i, length)
            add(.syntax, close, length)
            protect(i, close + length - i)
            i = close + length
        }
    }

    private static let autolink = try! NSRegularExpression(pattern: #"<[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^\s<>]*>"#)
    private static let emailAutolink = try! NSRegularExpression(pattern: #"<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~\-]+@[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*>"#)
    private static let htmlComment = try! NSRegularExpression(pattern: #"<!--.*?-->"#)
    private static let htmlTag = try! NSRegularExpression(
        pattern: #"</?[A-Za-z][A-Za-z0-9\-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:\-]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*/?>"#
    )

    private func anchoredMatch(_ regex: NSRegularExpression, at location: Int) -> NSRange? {
        let match = regex.firstMatch(in: text as String, options: .anchored, range: NSRange(location: location, length: end - location))
        guard let range = match?.range, range.location != NSNotFound else { return nil }
        for i in range.location..<NSMaxRange(range) where protected[i] { return nil }
        return range
    }

    private mutating func scanAngleConstructs() {
        var i = start
        while i < end {
            guard char(i) == 0x3C, !protected[i] else {
                i += 1
                continue
            }
            if let range = anchoredMatch(Self.autolink, at: i) ?? anchoredMatch(Self.emailAutolink, at: i) {
                add(.syntax, range.location, 1)
                add(.url, range.location + 1, range.length - 2)
                add(.syntax, NSMaxRange(range) - 1, 1)
                protect(range.location, range.length)
                i = NSMaxRange(range)
            } else if let range = anchoredMatch(Self.htmlComment, at: i) ?? anchoredMatch(Self.htmlTag, at: i) {
                add(.html, range.location, range.length)
                protect(range.location, range.length)
                i = NSMaxRange(range)
            } else {
                i += 1
            }
        }
    }

    private func matchingBracket(from open: Int, opening: unichar, closing: unichar) -> Int? {
        var depth = 0
        var i = open
        while i < end {
            if !protected[i] {
                let c = char(i)
                if c == opening {
                    depth += 1
                } else if c == closing {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    private mutating func scanLinks() {
        var i = start
        while i < end {
            guard char(i) == 0x5B, !protected[i], let close = matchingBracket(from: i, opening: 0x5B, closing: 0x5D) else {
                i += 1
                continue
            }
            let isImage = i > start && char(i - 1) == 0x21 && !protected[i - 1]
            let opener = isImage ? i - 1 : i
            let next = close + 1
            if next < end, char(next) == 0x28, !protected[next],
               let paren = matchingBracket(from: next, opening: 0x28, closing: 0x29) {
                add(.syntax, opener, i + 1 - opener)
                add(.linkText, i + 1, close - i - 1)
                add(.syntax, close, 2)
                add(.url, next + 1, paren - next - 1)
                add(.syntax, paren, 1)
                protect(next, paren + 1 - next)
            } else if next < end, char(next) == 0x5B, !protected[next],
                      let reference = matchingBracket(from: next, opening: 0x5B, closing: 0x5D) {
                add(.syntax, opener, i + 1 - opener)
                add(.linkText, i + 1, close - i - 1)
                add(.syntax, close, 2)
                add(.url, next + 1, reference - next - 1)
                add(.syntax, reference, 1)
                protect(next, reference + 1 - next)
            }
            i += 1
        }
    }

    private func masked(extra: Set<Int> = []) -> String {
        var units = Array((text.substring(with: NSRange(location: 0, length: end)) as String).utf16)
        for i in 0..<units.count where i < start || protected[i] || extra.contains(i) {
            units[i] = 0x01
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static let bareURL = try! NSRegularExpression(
        pattern: #"(?<![\w/@])(?:https?://|www\.)[^\s<>\u0001]*[^\s<>\u0001.,:;!?"'*_~)\]]"#
    )

    private mutating func scanBareURLs() {
        let string = masked()
        let range = NSRange(location: start, length: end - start)
        for match in Self.bareURL.matches(in: string, range: range) {
            add(.url, match.range.location, match.range.length)
            protect(match.range.location, match.range.length)
        }
    }

    private static let strongStar = try! NSRegularExpression(pattern: #"(?<![\\*])\*\*(?![\s*])(.+?)(?<![\s\\])\*\*"#)
    private static let strongUnderscore = try! NSRegularExpression(pattern: #"(?<![\w\\])__(?![\s_])(.+?)(?<![\s\\])__(?!\w)"#)
    private static let strike = try! NSRegularExpression(pattern: #"(?<![~\\])~~(?![\s~])(.+?)(?<![\s\\])~~(?!~)"#)
    private static let emphasisStar = try! NSRegularExpression(pattern: #"(?<![\\*])\*(?![\s*])(.+?)(?<![\s\\*])\*(?!\*)"#)
    private static let emphasisUnderscore = try! NSRegularExpression(pattern: #"(?<![\w\\_])_(?![\s_])(.+?)(?<![\s\\_])_(?![\w_])"#)

    private mutating func scanDelimiters() {
        let range = NSRange(location: start, length: end - start)
        var delimiters = Set<Int>()
        let first = masked()
        for (regex, kind, width) in [
            (Self.strongStar, SourceInlineToken.Kind.strong, 2),
            (Self.strongUnderscore, .strong, 2),
            (Self.strike, .strikethrough, 2)
        ] {
            for match in regex.matches(in: first, range: range) {
                let whole = match.range
                add(kind, whole.location + width, whole.length - width * 2)
                add(.syntax, whole.location, width)
                add(.syntax, NSMaxRange(whole) - width, width)
                for offset in 0..<width {
                    delimiters.insert(whole.location + offset)
                    delimiters.insert(NSMaxRange(whole) - width + offset)
                }
            }
        }
        let second = masked(extra: delimiters)
        for regex in [Self.emphasisStar, Self.emphasisUnderscore] {
            for match in regex.matches(in: second, range: range) {
                let whole = match.range
                add(.emphasis, whole.location + 1, whole.length - 2)
                add(.syntax, whole.location, 1)
                add(.syntax, NSMaxRange(whole) - 1, 1)
            }
        }
    }

    private mutating func scanPipes() {
        for i in start..<end where char(i) == 0x7C && !protected[i] {
            add(.syntax, i, 1)
        }
    }
}
