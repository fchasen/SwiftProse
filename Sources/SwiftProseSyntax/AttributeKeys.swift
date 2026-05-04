import Foundation

public extension NSAttributedString.Key {
    static let proseLink = NSAttributedString.Key("swiftprose.link")
    static let proseInline = NSAttributedString.Key("swiftprose.inline")
    /// Flag (Bool=true) on rendered list-marker characters (`•`, `1.`, etc.)
    /// the compiler injects so they aren't part of the markdown round-trip.
    static let proseListMarker = NSAttributedString.Key("swiftprose.listMarker")
    /// Flag (Bool=true) on every character of a pipe-table alignment row
    /// paragraph (e.g. `| :--- | --: |`). The layout fragment reads this to
    /// suppress drawing of the literal dashes when the table is rendered;
    /// raw mode skips the suppression and the row prints normally.
    static let proseTableAlignmentRow = NSAttributedString.Key("swiftprose.tableAlignmentRow")
    /// Flag (Bool=true) on every character of a pipe-table header row
    /// paragraph. Layout fragment uses it to paint a tinted background
    /// stripe behind the header.
    static let proseTableHeader = NSAttributedString.Key("swiftprose.tableHeader")
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
