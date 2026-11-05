import Foundation

package struct SourceListMarker: Equatable {
    package enum Kind: Equatable {
        case bullet(Character)
        case ordered(number: Int, delimiter: Character)
    }

    package var kind: Kind
    package var length: Int

    var isOrdered: Bool {
        if case .ordered = kind { return true }
        return false
    }
}

package struct SourceLinePrefix: Equatable {
    package var quoteDepth = 0
    package var quoteEnd = 0
    package var indentEnd = 0
    package var marker: SourceListMarker?
    package var markerEnd = 0
    package var task: Bool?
    package var taskEnd = 0
    package var heading: Int?
    package var contentStart = 0

    package var indent: Int { indentEnd - quoteEnd }
    var isListItem: Bool { marker != nil }
}

package struct SourceLine {
    package var range: NSRange
    package var prefix: SourceLinePrefix
    package var isBlank: Bool

    var start: Int { range.location }
    var end: Int { NSMaxRange(range) }
    var contentRange: NSRange { NSRange(location: start + prefix.contentStart, length: range.length - prefix.contentStart) }

    package init(range: NSRange, prefix: SourceLinePrefix, isBlank: Bool) {
        self.range = range
        self.prefix = prefix
        self.isBlank = isBlank
    }
}

struct SourceFence {
    var open: Int
    var close: Int?
    var lastLine: Int { close ?? open }
}

enum SourceCodeRole: Equatable {
    case fence(Int)
    case content(Int)
}

package struct SourceDocument {
    let ns: NSString
    let lines: [SourceLine]
    let fences: [SourceFence]
    let codeRoles: [SourceCodeRole?]

    init(_ text: String) {
        ns = text as NSString
        var lines: [SourceLine] = []
        var start = 0
        let length = ns.length
        while true {
            var end = start
            while end < length, ns.character(at: end) != 0x0A { end += 1 }
            let range = NSRange(location: start, length: end - start)
            lines.append(SourceLine(
                range: range,
                prefix: Self.parsePrefix(ns, range),
                isBlank: Self.isBlank(ns, range)
            ))
            if end >= length { break }
            start = end + 1
        }
        self.lines = lines
        (fences, codeRoles) = Self.scanFences(ns, lines)
    }

    package var length: Int { ns.length }

    func string(_ range: NSRange) -> String { ns.substring(with: range) }

    func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func selectedLines(_ selection: NSRange) -> ClosedRange<Int> {
        let first = lineIndex(containing: selection.location)
        var last = lineIndex(containing: NSMaxRange(selection))
        if selection.length > 0, last > first, lines[last].start == NSMaxRange(selection) { last -= 1 }
        return first...last
    }

    func isCode(_ index: Int) -> Bool { codeRoles[index] != nil }

    func isCodeContent(_ index: Int) -> Bool {
        if case .content = codeRoles[index] { return true }
        return false
    }

    func fenceIndex(_ index: Int) -> Int? {
        switch codeRoles[index] {
        case .fence(let f), .content(let f): return f
        case nil: return nil
        }
    }

    func isContinuation(_ index: Int) -> Bool {
        let line = lines[index]
        guard !line.isBlank, !line.prefix.isListItem, line.prefix.indent > 0, !isCode(index) else { return false }
        var i = index - 1
        while i >= 0 {
            let previous = lines[i]
            if previous.isBlank || isCode(i) { return false }
            if previous.prefix.isListItem { return line.prefix.indent >= previous.prefix.indent + 1 }
            i -= 1
        }
        return false
    }

    package static func isBlank(_ ns: NSString, _ range: NSRange) -> Bool {
        for i in range.location..<NSMaxRange(range) where !isSpace(ns.character(at: i)) { return false }
        return true
    }

    package static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

    package static func parsePrefix(_ ns: NSString, _ range: NSRange) -> SourceLinePrefix {
        let base = range.location
        let end = NSMaxRange(range)
        func at(_ i: Int) -> unichar? { base + i < end ? ns.character(at: base + i) : nil }
        func endsToken(_ i: Int) -> Bool {
            guard let c = at(i) else { return true }
            return isSpace(c)
        }

        var prefix = SourceLinePrefix()
        var pos = 0
        while true {
            var probe = pos
            var spaces = 0
            while spaces < 3, at(probe) == 0x20 { probe += 1; spaces += 1 }
            guard at(probe) == 0x3E else { break }
            probe += 1
            if at(probe) == 0x20 { probe += 1 }
            pos = probe
            prefix.quoteDepth += 1
        }
        prefix.quoteEnd = pos
        while let c = at(pos), isSpace(c) { pos += 1 }
        prefix.indentEnd = pos

        if let c = at(pos), c == 0x2D || c == 0x2A || c == 0x2B, endsToken(pos + 1),
           !isThematicBreak(ns, NSRange(location: base + pos, length: end - base - pos)) {
            let markerLength = at(pos + 1) == nil ? 1 : 2
            prefix.marker = SourceListMarker(kind: .bullet(Character(UnicodeScalar(c)!)), length: markerLength)
            pos += markerLength
        } else if let c = at(pos), isDigit(c) {
            var probe = pos
            while let d = at(probe), isDigit(d), probe - pos < 9 { probe += 1 }
            if let delimiter = at(probe), delimiter == 0x2E || delimiter == 0x29, endsToken(probe + 1) {
                let number = Int(ns.substring(with: NSRange(location: base + pos, length: probe - pos))) ?? 1
                let markerLength = probe + 1 - pos + (at(probe + 1) == nil ? 0 : 1)
                prefix.marker = SourceListMarker(
                    kind: .ordered(number: number, delimiter: Character(UnicodeScalar(delimiter)!)),
                    length: markerLength
                )
                pos += markerLength
            }
        }
        prefix.markerEnd = pos
        if prefix.marker != nil, at(pos) == 0x5B, let mark = at(pos + 1),
           mark == 0x20 || mark == 0x78 || mark == 0x58, at(pos + 2) == 0x5D, endsToken(pos + 3) {
            prefix.task = mark != 0x20
            pos += at(pos + 3) == nil ? 3 : 4
        }
        prefix.taskEnd = pos

        var hashes = 0
        while at(pos + hashes) == 0x23 { hashes += 1 }
        if hashes >= 1, hashes <= 6, endsToken(pos + hashes) {
            prefix.heading = hashes
            pos += hashes + (at(pos + hashes) == nil ? 0 : 1)
        }
        prefix.contentStart = pos
        return prefix
    }

    package static func isThematicBreak(_ ns: NSString, _ range: NSRange) -> Bool {
        var marker: unichar = 0
        var count = 0
        for i in range.location..<NSMaxRange(range) {
            let c = ns.character(at: i)
            if isSpace(c) { continue }
            guard c == 0x2D || c == 0x2A || c == 0x5F else { return false }
            if marker == 0 { marker = c } else if c != marker { return false }
            count += 1
        }
        return count >= 3
    }

    package static func fenceRun(_ ns: NSString, _ line: SourceLine) -> (char: unichar, length: Int, end: Int)? {
        var pos = line.start + line.prefix.quoteEnd
        let end = line.end
        while pos < end, isSpace(ns.character(at: pos)) { pos += 1 }
        guard pos < end else { return nil }
        let c = ns.character(at: pos)
        guard c == 0x60 || c == 0x7E else { return nil }
        var run = pos
        while run < end, ns.character(at: run) == c { run += 1 }
        guard run - pos >= 3 else { return nil }
        return (c, run - pos, run)
    }

    static func scanFences(_ ns: NSString, _ lines: [SourceLine]) -> ([SourceFence], [SourceCodeRole?]) {
        var fences: [SourceFence] = []
        var roles = [SourceCodeRole?](repeating: nil, count: lines.count)
        var open: (char: unichar, length: Int, line: Int)?
        for (index, line) in lines.enumerated() {
            if let current = open {
                if let run = fenceRun(ns, line), run.char == current.char, run.length >= current.length,
                   isBlank(ns, NSRange(location: run.end, length: line.end - run.end)) {
                    fences[fences.count - 1].close = index
                    roles[index] = .fence(fences.count - 1)
                    open = nil
                } else {
                    roles[index] = .content(fences.count - 1)
                }
                continue
            }
            guard let run = fenceRun(ns, line) else { continue }
            if run.char == 0x60 {
                let info = ns.substring(with: NSRange(location: run.end, length: line.end - run.end))
                if info.contains("`") { continue }
            }
            fences.append(SourceFence(open: index, close: nil))
            roles[index] = .fence(fences.count - 1)
            open = (run.char, run.length, index)
        }
        return (fences, roles)
    }
}
