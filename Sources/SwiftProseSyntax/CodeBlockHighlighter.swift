import Foundation
import SwiftTreeSitter

/// Produces token highlight spans for the body text of a fenced or indented
/// code block. Spans are returned in `NSRange` (UTF-16) coordinates relative
/// to `source` (i.e. starting at 0); the caller offsets them into document
/// coordinates.
public protocol CodeBlockHighlighter: AnyObject {
    func highlights(for source: String, language: String?) -> [HighlightSpan]
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
}
