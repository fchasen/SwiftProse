import Foundation
import SwiftTreeSitter

/// Produces token highlight spans for the body text of a fenced or indented
/// code block. Spans are returned in `NSRange` (UTF-16) coordinates relative
/// to `source` (i.e. starting at 0); the caller offsets them into document
/// coordinates.
public protocol CodeBlockHighlighter: AnyObject {
    func highlights(for source: String, language: String?) -> [HighlightSpan]

    /// Best-guess language name (must be one the highlighter knows about) for
    /// a body whose fence had no info string. Return nil when the body is
    /// short, ambiguous, or no registered grammar parses it cleanly — the
    /// caller treats nil as "leave the body uncolored." Default
    /// implementation returns nil.
    func detectLanguage(for source: String) -> String?
}

extension CodeBlockHighlighter {
    public func detectLanguage(for source: String) -> String? { nil }
}

/// Registry-based highlighter that runs a tree-sitter grammar + `highlights.scm`
/// query for each registered language. The host registers `(Language, Query
/// data)` pairs at startup; the compiler calls `highlights(for:language:)`
/// during code-block emission.
///
/// Safe to share across threads after `register` calls have settled: each
/// `highlights(...)` call constructs its own `Parser`. `register` itself is
/// not thread-safe — call it during setup before handing the highlighter to
/// `EditorController`.
public final class TreeSitterCodeBlockHighlighter: CodeBlockHighlighter, @unchecked Sendable {
    private struct Entry {
        let language: Language
        let query: Query
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func register(language name: String, language: Language, queryData: Data) throws {
        let query = try Query(language: language, data: queryData)
        entries[name.lowercased()] = Entry(language: language, query: query)
    }

    public var registeredLanguages: [String] {
        Array(entries.keys).sorted()
    }

    public func highlights(for source: String, language: String?) -> [HighlightSpan] {
        guard let raw = language?.lowercased(), !raw.isEmpty,
              let entry = entries[raw] else { return [] }
        return runQuery(source: source, entry: entry)
    }

    /// Detect by parsing `source` with every registered grammar and choosing
    /// the one whose query covers the most characters. Returns nil unless one
    /// language clearly wins:
    /// - covers ≥ 30% of source chars, AND
    /// - covers ≥ 1.5× as many chars as the runner-up
    /// These thresholds are deliberately strict so false-positive coloring on
    /// plain prose / config / log lines stays off. Tied languages produce nil.
    public func detectLanguage(for source: String) -> String? {
        let totalChars = (source as NSString).length
        guard totalChars >= 16 else { return nil }
        var best: (name: String, coverage: Int) = ("", 0)
        var second: (name: String, coverage: Int) = ("", 0)
        for name in entries.keys.sorted() {
            guard let entry = entries[name] else { continue }
            let spans = runQuery(source: source, entry: entry)
            // Sum unique covered chars (merge overlaps so e.g. a punctuation
            // span inside a string span isn't double-counted).
            let coverage = unionLength(of: spans.map(\.range))
            if coverage > best.coverage {
                second = best
                best = (name, coverage)
            } else if coverage > second.coverage {
                second = (name, coverage)
            }
        }
        guard best.coverage > 0 else { return nil }
        let bestRatio = Double(best.coverage) / Double(totalChars)
        let edge = second.coverage == 0 ? .infinity : Double(best.coverage) / Double(second.coverage)
        guard bestRatio >= 0.30, edge >= 1.5 else { return nil }
        return best.name
    }

    private func runQuery(source: String, entry: Entry) -> [HighlightSpan] {
        let parser = Parser()
        do {
            try parser.setLanguage(entry.language)
        } catch {
            return []
        }
        guard let tree = parser.parse(source),
              let root = tree.rootNode else { return [] }
        let mapping = TreeSitterMapping(text: source)
        let cursor = entry.query.execute(node: root, in: tree)
        let named = cursor.highlights()
        return named.map { nr in
            let name = nr.nameComponents.joined(separator: ".")
            let tag = name.isEmpty ? HighlightTag.unknown : HighlightTag(captureName: name)
            let lo = mapping.utf16Offset(forByte: nr.tsRange.bytes.lowerBound)
            let hi = mapping.utf16Offset(forByte: nr.tsRange.bytes.upperBound)
            return HighlightSpan(range: NSRange(location: lo, length: hi - lo), tag: tag)
        }
    }

    private func unionLength(of ranges: [NSRange]) -> Int {
        guard !ranges.isEmpty else { return 0 }
        let sorted = ranges.sorted { $0.location < $1.location }
        var total = 0
        var cursor = sorted[0].location
        var end = cursor
        for r in sorted {
            if r.location > end {
                total += end - cursor
                cursor = r.location
                end = r.location + r.length
            } else {
                end = max(end, r.location + r.length)
            }
        }
        total += end - cursor
        return total
    }
}
