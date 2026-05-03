import Foundation

public extension NSAttributedString.Key {
    static let marginaliaLink = NSAttributedString.Key("marginalia.link")
    static let marginaliaInline = NSAttributedString.Key("marginalia.inline")
    /// Flag (Bool=true) on rendered list-marker characters (`•`, `1.`, etc.)
    /// the compiler injects so they aren't part of the markdown round-trip.
    static let marginaliaListMarker = NSAttributedString.Key("marginalia.listMarker")
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
