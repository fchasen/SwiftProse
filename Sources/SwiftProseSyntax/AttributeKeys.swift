import Foundation

public extension NSAttributedString.Key {
    static let proseLink = NSAttributedString.Key("swiftprose.link")
    static let proseInline = NSAttributedString.Key("swiftprose.inline")
    /// Flag (Bool=true) on rendered list-marker characters (`•`, `1.`, etc.)
    /// the compiler injects so they aren't part of the markdown round-trip.
    static let proseListMarker = NSAttributedString.Key("swiftprose.listMarker")
    /// Hierarchical structural attribute. Carries a `NodePathBox` per
    /// character so the document tree can be reconstructed from attribute
    /// runs. The compiler stamps it during emit; readers like
    /// `BlockSpecDecorationProvider`, `LayoutManagerDelegate`,
    /// `ProseDocument.from(storage:)` and `MarkdownTreeSerializer` walk it
    /// to drive their per-paragraph dispatch.
    static let proseNodePath = NSAttributedString.Key("swiftprose.nodePath")
    /// Canonical inline marks (bold, italic, code, link, strike) per character
    /// as a `MarkSetBox`. Layout layer projects these onto the existing
    /// rendering attributes (font traits, foreground color, code-span pill).
    static let proseMarks = NSAttributedString.Key("swiftprose.marks")
}

public enum BlockTag: String, Sendable, Hashable, CaseIterable {
    case paragraph
    case heading
    case unorderedListItem
    case orderedListItem
    case taskListItem
    case fencedCode
    case indentedCode
    case horizontalRule
    case htmlBlock
    case linkReferenceDefinition
    case pipeTable
}

public enum InlineTag: String, Sendable, Hashable, CaseIterable {
    case emphasis
    case strong
    case strikethrough
    case codeSpan
    case link
    case rawHTML
}

public enum ListItemKind: String, Sendable, Hashable, CaseIterable {
    case bullet
    case ordered
    case task
}
