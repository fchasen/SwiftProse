import Foundation

package enum SourceSelectionMapping {
    static let anchorLength = 8
    static let searchWindow = 4096

    package static func sourceRange(forRich range: NSRange, rich: NSString, source: NSString) -> NSRange {
        let start = sourceLocation(forRich: range.location, rich: rich, source: source)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        let end = sourceLocation(forRich: NSMaxRange(range), rich: rich, source: source, trailing: true)
        return NSRange(location: start, length: max(0, end - start))
    }

    package static func richRange(forSource range: NSRange, rich: NSString, source: NSString) -> NSRange {
        let start = richLocation(forSource: range.location, rich: rich, source: source)
        guard range.length > 0 else { return NSRange(location: start, length: 0) }
        let end = richLocation(forSource: NSMaxRange(range), rich: rich, source: source)
        return NSRange(location: start, length: max(0, end - start))
    }

    static func sourceLocation(forRich location: Int, rich: NSString, source: NSString, trailing: Bool = false) -> Int {
        let target = max(0, min(location, rich.length))
        var walker = Walker(rich: rich, source: source)
        while walker.i < target { walker.advance() }
        guard !trailing || target == 0, walker.i < rich.length, let match = walker.match() else {
            return min(walker.j, source.length)
        }
        return match
    }

    static func richLocation(forSource location: Int, rich: NSString, source: NSString) -> Int {
        let target = max(0, min(location, source.length))
        var walker = Walker(rich: rich, source: source)
        while walker.i < rich.length, walker.j < target {
            guard let match = walker.match() else {
                walker.i += 1
                continue
            }
            if match >= target { return walker.i }
            walker.i += 1
            walker.j = match + 1
        }
        return walker.i
    }

    private struct Walker {
        let rich: NSString
        let source: NSString
        var i = 0
        var j = 0

        init(rich: NSString, source: NSString) {
            self.rich = rich
            self.source = source
        }

        func match() -> Int? {
            let c = rich.character(at: i)
            if j < source.length, source.character(at: j) == c { return j }
            var end = i
            if c == 0x0A {
                end = i + 1
            } else {
                while end < rich.length, end - i < SourceSelectionMapping.anchorLength, !Self.isStructural(rich.character(at: end)) {
                    end += 1
                }
            }
            guard end > i, j < source.length else { return nil }
            let window = NSRange(location: j, length: min(source.length - j, SourceSelectionMapping.searchWindow))
            var length = end - i
            while length > 0 {
                let anchor = rich.substring(with: NSRange(location: i, length: length))
                let found = source.range(of: anchor, options: .literal, range: window)
                if found.location != NSNotFound { return found.location }
                length /= 2
            }
            return nil
        }

        mutating func advance() {
            if let match = match() {
                j = match + 1
            }
            i += 1
        }

        static func isStructural(_ c: unichar) -> Bool {
            c == 0x09 || c == 0x0A || c == 0xFFFC || c == 0x2028 || c == 0x2029
        }
    }
}
