import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

/// A live, incremental tree-sitter parser specialized to one of the two
/// Markdown grammars that ship with `tree-sitter-grammars/tree-sitter-markdown`:
///
/// - `.block` — the outer grammar that recognizes paragraphs, headings, fences,
///   blockquotes, lists, etc., and emits opaque `inline` nodes for the text
///   inside them.
/// - `.inline` — the injected grammar that recognizes emphasis, code spans,
///   links, autolinks, etc. inside an `inline` node.
///
/// `MarkdownParser` keeps the previous tree around so each `applyEdit` does an
/// incremental re-parse rather than re-tokenizing the whole document.
public final class MarkdownParser {
    public enum Grammar: Sendable {
        case block
        case inline
    }

    public let grammar: Grammar
    public private(set) var mapping: TreeSitterMapping
    public private(set) var tree: MutableTree?
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
        self.tree = nil
    }

    /// Reset to a fresh parse of the entire `source`.
    @discardableResult
    public func parse(_ source: String) -> MutableTree? {
        self.mapping = TreeSitterMapping(text: source)
        self.tree = parser.parse(source)
        return self.tree
    }

    /// Apply a single edit incrementally.
    ///
    /// `nsRange` and `replacement` describe the edit *against the current
    /// `mapping.text`*; `newSource` must be the result of applying that edit.
    /// Returns the byte-ranges (in the new text) whose syntactic role changed.
    @discardableResult
    public func applyEdit(replacing nsRange: NSRange, with replacement: String, newSource: String) -> [TSRange] {
        guard let oldTree = self.tree else {
            self.parse(newSource)
            let mapping = TreeSitterMapping(text: newSource)
            let endByte = mapping.byteOffset(forUTF16: (newSource as NSString).length)
            let endPoint = mapping.point(forByte: endByte)
            return [TSRange(
                points: Point.zero..<endPoint,
                bytes: 0..<endByte
            )]
        }

        let edit = mapping.makeInputEdit(replacing: nsRange, with: replacement)
        oldTree.edit(edit)
        let newMapping = TreeSitterMapping(text: newSource)
        guard let newTree = parser.parse(tree: oldTree, string: newSource) else {
            self.tree = nil
            self.mapping = newMapping
            return []
        }
        let changed = oldTree.changedRanges(from: newTree)
        self.tree = newTree
        self.mapping = newMapping
        return changed
    }

    public var rootNode: Node? { tree?.rootNode }
}
