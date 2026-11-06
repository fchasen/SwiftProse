import Foundation
import SwiftProseSyntax
import SwiftTreeSitter

/// A `CodeBlockHighlighter` that runs a registered tree-sitter grammar and
/// `highlights.scm` query per language and colours captures through a
/// `CodePalette`.
///
/// Register every language before handing the highlighter to an editor.
/// A fence with no info string is classified with `detectLanguage(for:)`.
public final class TreeSitterCodeBlockHighlighter: CodeBlockHighlighter {
    struct Entry {
        let language: Language
        let query: Query
    }

    public var palette: CodePalette
    private var entries: [String: Entry] = [:]

    public init(palette: CodePalette = .default) {
        self.palette = palette
    }

    public func register(language name: String, language: Language, queryData: Data) throws {
        let query = try Query(language: language, data: queryData)
        entries[name.lowercased()] = Entry(language: language, query: query)
    }

    public var registeredLanguages: [String] {
        entries.keys.sorted()
    }

    /// The registered language that clearly covers `source` best, or nil
    /// when the body is short, ambiguous or unrecognised.
    public func detectLanguage(for source: String) -> String? {
        LanguageDetection.detect(in: source, candidates: registeredLanguages) { name in
            entries[name].map { spans(in: source, entry: $0).map(\.range) } ?? []
        }
    }

    /// Tagged spans for `source` parsed as `language`; empty when the
    /// language is not registered.
    public func highlights(for source: String, language: String) -> [HighlightSpan] {
        guard let entry = entries[language.lowercased()] else { return [] }
        return spans(in: source, entry: entry)
    }

    public func makeSession(language: String?, body: String) -> CodeHighlightSession? {
        let requested = language?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if requested.isEmpty {
            guard !entries.isEmpty else { return nil }
            return TreeSitterSession(highlighter: self, language: nil)
        }
        guard entries[requested] != nil else { return nil }
        return TreeSitterSession(highlighter: self, language: requested)
    }

    func runs(for body: String, language: String) -> [CodeHighlightRun] {
        highlights(for: body, language: language).compactMap { span in
            guard span.range.length > 0, let color = palette.color(for: span.tag) else { return nil }
            return CodeHighlightRun(range: span.range, color: color)
        }
    }

    private func spans(in source: String, entry: Entry) -> [HighlightSpan] {
        let parser = Parser()
        guard (try? parser.setLanguage(entry.language)) != nil,
              let tree = parser.parse(source),
              let root = tree.rootNode
        else { return [] }
        let mapping = TreeSitterMapping(text: source)
        let length = (source as NSString).length
        return entry.query.execute(node: root, in: tree).highlights().compactMap { named in
            let name = named.nameComponents.joined(separator: ".")
            let tag = name.isEmpty ? HighlightTag.unknown : HighlightTag(captureName: name)
            let lower = min(length, mapping.utf16Offset(forByte: named.tsRange.bytes.lowerBound))
            let upper = min(length, mapping.utf16Offset(forByte: named.tsRange.bytes.upperBound))
            guard upper >= lower else { return nil }
            return HighlightSpan(range: NSRange(location: lower, length: upper - lower), tag: tag)
        }
    }
}

/// Re-parses the whole body on every edit. A session opened without a
/// language re-detects until a language is found.
final class TreeSitterSession: CodeHighlightSession {
    private let highlighter: TreeSitterCodeBlockHighlighter
    private let isDetecting: Bool
    private(set) var language: String?

    init(highlighter: TreeSitterCodeBlockHighlighter, language: String?) {
        self.highlighter = highlighter
        self.language = language
        self.isDetecting = language == nil
    }

    func reset(body: String) -> [CodeHighlightRun] {
        runs(for: body)
    }

    func didEdit(replacedRange: NSRange, replacement: String, body: String) -> CodeHighlightEdit {
        CodeHighlightEdit(
            invalidatedRange: NSRange(location: 0, length: (body as NSString).length),
            runs: runs(for: body)
        )
    }

    private func runs(for body: String) -> [CodeHighlightRun] {
        if isDetecting { language = highlighter.detectLanguage(for: body) }
        guard let language else { return [] }
        return highlighter.runs(for: body, language: language)
    }
}
