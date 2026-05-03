import Foundation
import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

/// One of the standard tree-sitter highlight tags emitted by the bundled
/// `highlights.scm` queries from `tree-sitter-grammars/tree-sitter-markdown`.
/// Mapped to attribute decisions in the editor.
public enum HighlightTag: String, Sendable, Equatable {
    case textTitle = "text.title"
    case textLiteral = "text.literal"
    case textEmphasis = "text.emphasis"
    case textStrong = "text.strong"
    case textURI = "text.uri"
    case textReference = "text.reference"
    case punctuationSpecial = "punctuation.special"
    case punctuationDelimiter = "punctuation.delimiter"
    case stringEscape = "string.escape"
    case none = "none"
    case unknown
}

extension HighlightTag {
    public init(captureName: String) {
        if let tag = HighlightTag(rawValue: captureName) {
            self = tag
            return
        }
        // The capture name might be hierarchical (e.g., "text.title.1"). Fall
        // back to the most-specific known prefix.
        var components = captureName.split(separator: ".").map(String.init)
        while !components.isEmpty {
            let candidate = components.joined(separator: ".")
            if let tag = HighlightTag(rawValue: candidate) {
                self = tag
                return
            }
            components.removeLast()
        }
        self = .unknown
    }
}

public struct HighlightSpan: Equatable, Sendable {
    /// UTF-16 code-unit range (`NSRange`-compatible) into the source text.
    public let range: NSRange
    public let tag: HighlightTag

    public init(range: NSRange, tag: HighlightTag) {
        self.range = range
        self.tag = tag
    }
}

/// Runs the bundled `highlights.scm` queries over a parsed tree-sitter tree
/// and emits `HighlightSpan`s in NSRange (UTF-16) coordinates.
///
/// The applier holds a single compiled `Query` per grammar — compiling .scm
/// data is expensive enough to amortize across calls.
public final class HighlightApplier {
    public enum Grammar: Sendable {
        case block, inline
    }

    public let blockQuery: Query
    public let inlineQuery: Query

    public init() throws {
        let blockLang = Language(language: tree_sitter_markdown())
        let inlineLang = Language(language: tree_sitter_markdown_inline())
        guard let blockData = HighlightApplier.blockHighlightsSource.data(using: .utf8),
              let inlineData = HighlightApplier.inlineHighlightsSource.data(using: .utf8) else {
            throw HighlightLoadError.encodingFailed
        }
        self.blockQuery = try Query(language: blockLang, data: blockData)
        self.inlineQuery = try Query(language: inlineLang, data: inlineData)
    }

    public enum HighlightLoadError: Error {
        case encodingFailed
    }

    public func highlights(rootNode: Node, in tree: MutableTree, mapping: TreeSitterMapping, grammar: Grammar) -> [HighlightSpan] {
        let query = (grammar == .block) ? blockQuery : inlineQuery
        let cursor = query.execute(node: rootNode, in: tree)
        let named = cursor.highlights()
        return named.compactMap { nr in
            guard let captureName = nr.nameComponents.first else { return nil }
            let fullName = nr.nameComponents.joined(separator: ".")
            let tag = HighlightTag(captureName: fullName) == .unknown
                ? HighlightTag(captureName: captureName)
                : HighlightTag(captureName: fullName)
            let lo = mapping.utf16Offset(forByte: nr.tsRange.bytes.lowerBound)
            let hi = mapping.utf16Offset(forByte: nr.tsRange.bytes.upperBound)
            return HighlightSpan(range: NSRange(location: lo, length: hi - lo), tag: tag)
        }
    }

    // Bundled queries from tree-sitter-grammars/tree-sitter-markdown@v0.5.3,
    // inlined here because the grammar package's resources aren't reachable
    // through `Bundle.module` from a downstream consumer target.
    static let blockHighlightsSource = #"""
    ;From nvim-treesitter/nvim-treesitter
    (atx_heading
      (inline) @text.title)

    (setext_heading
      (paragraph) @text.title)

    [
      (atx_h1_marker)
      (atx_h2_marker)
      (atx_h3_marker)
      (atx_h4_marker)
      (atx_h5_marker)
      (atx_h6_marker)
      (setext_h1_underline)
      (setext_h2_underline)
    ] @punctuation.special

    [
      (link_title)
      (indented_code_block)
      (fenced_code_block)
    ] @text.literal

    (fenced_code_block_delimiter) @punctuation.delimiter

    (code_fence_content) @none

    (link_destination) @text.uri

    (link_label) @text.reference

    [
      (list_marker_plus)
      (list_marker_minus)
      (list_marker_star)
      (list_marker_dot)
      (list_marker_parenthesis)
      (thematic_break)
    ] @punctuation.special

    [
      (block_continuation)
      (block_quote_marker)
    ] @punctuation.special

    (backslash_escape) @string.escape
    """#

    static let inlineHighlightsSource = #"""
    ; From nvim-treesitter/nvim-treesitter
    [
      (code_span)
      (link_title)
    ] @text.literal

    [
      (emphasis_delimiter)
      (code_span_delimiter)
    ] @punctuation.delimiter

    (emphasis) @text.emphasis

    (strong_emphasis) @text.strong

    (uri_autolink) @text.uri

    (image
      (link_destination) @text.uri)

    [
      (link_label)
      (link_text)
      (image_description)
    ] @text.reference

    [
      (backslash_escape)
      (hard_line_break)
    ] @string.escape

    (image
      [
        "!"
        "["
        "]"
        "("
        ")"
      ] @punctuation.delimiter)

    (inline_link
      [
        "["
        "]"
        "("
        ")"
        (link_destination)
      ] @punctuation.delimiter)

    (shortcut_link
      [
        "["
        "]"
      ] @punctuation.delimiter)
    """#
}
