import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Foreground colours for highlighted code, keyed by `HighlightTag`.
public struct CodePalette: Equatable {
    public var keyword: PlatformColor
    public var string: PlatformColor
    public var comment: PlatformColor
    public var number: PlatformColor
    public var type: PlatformColor
    public var function: PlatformColor
    public var variable: PlatformColor
    public var constant: PlatformColor
    public var attribute: PlatformColor
    public var op: PlatformColor
    public var punctuation: PlatformColor

    public init(
        keyword: PlatformColor,
        string: PlatformColor,
        comment: PlatformColor,
        number: PlatformColor,
        type: PlatformColor,
        function: PlatformColor,
        variable: PlatformColor,
        constant: PlatformColor,
        attribute: PlatformColor,
        op: PlatformColor,
        punctuation: PlatformColor
    ) {
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.number = number
        self.type = type
        self.function = function
        self.variable = variable
        self.constant = constant
        self.attribute = attribute
        self.op = op
        self.punctuation = punctuation
    }

    public static var `default`: CodePalette {
        #if canImport(AppKit) && os(macOS)
        CodePalette(
            keyword: .systemPurple,
            string: .systemRed,
            comment: .secondaryLabelColor,
            number: .systemTeal,
            type: .systemBlue,
            function: .systemIndigo,
            variable: .labelColor,
            constant: .systemOrange,
            attribute: .systemTeal,
            op: .systemPink,
            punctuation: .tertiaryLabelColor
        )
        #else
        CodePalette(
            keyword: .systemPurple,
            string: .systemRed,
            comment: .secondaryLabel,
            number: .systemTeal,
            type: .systemBlue,
            function: .systemIndigo,
            variable: .label,
            constant: .systemOrange,
            attribute: .systemTeal,
            op: .systemPink,
            punctuation: .tertiaryLabel
        )
        #endif
    }

    /// The colour for `tag`, or nil to leave the run in the code block's
    /// base colour.
    public func color(for tag: HighlightTag) -> PlatformColor? {
        switch tag {
        case .keyword: keyword
        case .string, .stringEscape: string
        case .comment: comment
        case .number, .boolean: number
        case .type: type
        case .function, .method: function
        case .variable, .parameter, .label: variable
        case .constant: constant
        case .attribute, .property, .tag: attribute
        case .op: op
        case .punctuationDelimiter, .punctuationBracket, .punctuationSpecial: punctuation
        case .none, .unknown: nil
        }
    }
}
