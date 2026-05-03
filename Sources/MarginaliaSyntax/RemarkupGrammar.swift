import Foundation
import SwiftTreeSitter
import TreeSitterRemarkup

/// Tree-sitter-backed overlay tokenizer for Phabricator's Remarkup
/// dialect. Runs as a *second* parse alongside `tree-sitter-markdown` —
/// markdown handles structure (paragraphs, headings, code, fences, lists,
/// blockquotes); this layer adds Remarkup-specific inline tokens:
///
/// - `//italic//`              → `.textEmphasis`
/// - `D123`, `T456`            → `.textURI` (revision / task autolinks)
/// - `{F1234}`, `{P567…}`      → `.textURI` (file / paste embeds)
/// - `@user`                   → `.textReference`
/// - `NOTE: WARNING: IMPORTANT: TODO:` (line start)
///                             → `.textTitle`
/// - `==Heading==`             → `.textTitle`
///
/// The grammar lives in `Vendor/tree-sitter-remarkup/` (regenerate with
/// `npx tree-sitter-cli generate` from that directory after editing
/// `grammar.js`). Word-boundary semantics fall out of the grammar's
/// `text` rule consuming contiguous word runs, so `D12` inside a word
/// like `fooD12bar` is *not* matched as a revision link.
public enum RemarkupGrammar {

    public static func highlights(in text: String) -> [HighlightSpan] {
        let spans = parser?.highlights(in: text) ?? []
        return spans.sorted { $0.range.location < $1.range.location }
    }

    // Parser is shared across calls so the compiled `Query` (the expensive
    // bit) is built only once.
    private static let parser: RemarkupParser? = try? RemarkupParser()
}

/// Owns the `SwiftTreeSitter.Parser` and compiled `Query` for the
/// Remarkup grammar. Separated from `RemarkupGrammar` so tests can
/// instantiate it directly without going through the singleton.
final class RemarkupParser {
    private let parser: Parser
    private let query: Query

    init() throws {
        self.parser = Parser()
        let language = Language(language: tree_sitter_remarkup())
        try parser.setLanguage(language)
        guard let queryData = Self.highlightsSource.data(using: .utf8) else {
            throw HighlightLoadError.encodingFailed
        }
        self.query = try Query(language: language, data: queryData)
    }

    enum HighlightLoadError: Error {
        case encodingFailed
    }

    func highlights(in text: String) -> [HighlightSpan] {
        guard let tree = parser.parse(text), let root = tree.rootNode else {
            return []
        }
        let cursor = query.execute(node: root, in: tree)
        let mapping = TreeSitterMapping(text: text)
        return cursor.highlights().compactMap { capture in
            let lo = mapping.utf16Offset(forByte: capture.tsRange.bytes.lowerBound)
            let hi = mapping.utf16Offset(forByte: capture.tsRange.bytes.upperBound)
            guard hi > lo else { return nil }
            let range = NSRange(location: lo, length: hi - lo)
            let captureName = capture.nameComponents.joined(separator: ".")
            let tag = HighlightTag(captureName: captureName)
            guard tag != .unknown else { return nil }
            // Tree-sitter doesn't have a `^` line-start anchor without an
            // external scanner, so the grammar will happily match callouts
            // and headings mid-line (`this WARNING: should not match`).
            // Filter those out here — for the Remarkup pass, every
            // `text.title` capture is a callout or heading, so we can
            // require them all to start at column 0.
            if tag == .textTitle, !isAtLineStart(range: range, in: text) {
                return nil
            }
            return HighlightSpan(range: range, tag: tag)
        }
    }

    private func isAtLineStart(range: NSRange, in text: String) -> Bool {
        guard range.location > 0 else { return true }
        let ns = text as NSString
        return ns.character(at: range.location - 1) == UInt16(0x0A)
    }

    static let highlightsSource: String = #"""
    (italic) @text.emphasis

    (revision_link) @text.uri
    (task_link) @text.uri

    (file_embed) @text.uri
    (paste_embed) @text.uri

    (user_mention) @text.reference

    (callout) @text.title
    (heading) @text.title
    """#
}
