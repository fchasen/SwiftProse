import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

/// A tree-sitter parser specialized to one of the two
/// Markdown grammars that ship with `tree-sitter-grammars/tree-sitter-markdown`:
///
/// - `.block` — the outer grammar that recognizes paragraphs, headings, fences,
///   blockquotes, lists, etc., and emits opaque `inline` nodes for the text
///   inside them.
/// - `.inline` — the injected grammar that recognizes emphasis, code spans,
///   links, autolinks, etc. inside an `inline` node.
///
/// Each `parse(_:)` is a full re-parse and returns the resulting tree;
/// the parser itself holds no tree state, only the UTF-16 ↔ byte `mapping`
/// for the text it last parsed.
public final class MarkdownParser {
    public enum Grammar: Sendable {
        case block
        case inline
    }

    public let grammar: Grammar
    public private(set) var mapping: TreeSitterMapping
    private let parser: Parser

    public init(grammar: Grammar = .block) throws {
        self.grammar = grammar
        self.parser = Parser()
        let language: Language
        switch grammar {
        case .block:  language = Language(language: tree_sitter_markdown())
        case .inline: language = Language(language: tree_sitter_markdown_inline())
        }
        try parser.setLanguage(language)
        self.mapping = TreeSitterMapping(text: "")
    }

    /// Parse the entire `source` and refresh `mapping` to match it.
    @discardableResult
    public func parse(_ source: String) -> MutableTree? {
        self.mapping = TreeSitterMapping(text: source)
        return parser.parse(source)
    }
}
