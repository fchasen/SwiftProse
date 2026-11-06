import Foundation

/// A tree-sitter `highlights.scm` capture name, reduced to the tags a
/// `CodePalette` colours.
public enum HighlightTag: String, Sendable, Equatable {
    case keyword = "keyword"
    case string = "string"
    case stringEscape = "string.escape"
    case comment = "comment"
    case number = "number"
    case boolean = "boolean"
    case constant = "constant"
    case function = "function"
    case method = "method"
    case variable = "variable"
    case parameter = "parameter"
    case type = "type"
    case attribute = "attribute"
    case property = "property"
    case label = "label"
    case op = "operator"
    case tag = "tag"
    case punctuationSpecial = "punctuation.special"
    case punctuationDelimiter = "punctuation.delimiter"
    case punctuationBracket = "punctuation.bracket"
    case none = "none"
    case unknown

    /// Resolves a dotted capture name to its most specific known prefix:
    /// `"function.method.builtin"` → `.function`.
    public init(captureName: String) {
        if let tag = HighlightTag(rawValue: captureName) {
            self = tag
            return
        }
        var components = captureName.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let tag = HighlightTag(rawValue: components.joined(separator: ".")) {
                self = tag
                return
            }
            components.removeLast()
        }
        self = .unknown
    }
}

/// A tagged UTF-16 range into a code-block body.
public struct HighlightSpan: Equatable, Sendable {
    public let range: NSRange
    public let tag: HighlightTag

    public init(range: NSRange, tag: HighlightTag) {
        self.range = range
        self.tag = tag
    }
}
