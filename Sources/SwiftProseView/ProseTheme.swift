import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Visual styling — the editor surface's only "design system" knob.
///
/// Defaults match the rest of the Zilla UI: system body font for prose,
/// monospaced system for fenced/code spans, secondary label for dimmed
/// markup, link color for URLs.
public struct ProseTheme: Equatable {
    public var bodyFont: PlatformFont
    public var monospaceFont: PlatformFont
    public var foregroundColor: PlatformColor
    public var markupColor: PlatformColor
    public var linkColor: PlatformColor
    /// Color for the URL/destination portion of a markdown link — dimmer than
    /// `linkColor` so the user reads the label, not the URL, as the
    /// "clickable" thing.
    public var linkURLColor: PlatformColor
    public var blockquoteBarColor: PlatformColor
    public var headingScale: [Int: CGFloat]
    public var codePalette: CodePalette
    public var tablePalette: TablePalette

    public init(
        bodyFont: PlatformFont,
        monospaceFont: PlatformFont,
        foregroundColor: PlatformColor,
        markupColor: PlatformColor,
        linkColor: PlatformColor,
        linkURLColor: PlatformColor,
        blockquoteBarColor: PlatformColor,
        headingScale: [Int: CGFloat] = [1: 1.6, 2: 1.4, 3: 1.25, 4: 1.15, 5: 1.05, 6: 1.0],
        codePalette: CodePalette = .default,
        tablePalette: TablePalette = .default
    ) {
        self.bodyFont = bodyFont
        self.monospaceFont = monospaceFont
        self.foregroundColor = foregroundColor
        self.markupColor = markupColor
        self.linkColor = linkColor
        self.linkURLColor = linkURLColor
        self.blockquoteBarColor = blockquoteBarColor
        self.headingScale = headingScale
        self.codePalette = codePalette
        self.tablePalette = tablePalette
    }

    public static var `default`: ProseTheme {
        Self.default(fontScale: 1.0)
    }

    /// Attribute set for a plain paragraph in this theme. Used everywhere
    /// the editor needs to demote a styled line back to an unstyled one
    /// (backspace at the start of a list item, exiting a heading, etc.).
    public func plainParagraphAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: foregroundColor,
            .paragraphStyle: NSParagraphStyle(),
            .proseBlockSpec: BlockSpecBox(.paragraph)
        ]
    }

    public func headingFont(level: Int) -> PlatformFont {
        let scale = headingScale[max(1, min(6, level))] ?? 1.0
        let size = bodyFont.pointSize * scale
        #if canImport(AppKit) && os(macOS)
        return NSFont.boldSystemFont(ofSize: size)
        #else
        return UIFont.boldSystemFont(ofSize: size)
        #endif
    }

    /// Per-tag foreground colors for syntax-highlighted code blocks. Returned
    /// from `colorFor(tag:)` and consumed by `MarkdownAttributedCompiler`
    /// when a `CodeBlockHighlighter` produces spans.
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
            return CodePalette(
                keyword: NSColor.systemPurple,
                string: NSColor.systemRed,
                comment: NSColor.secondaryLabelColor,
                number: NSColor.systemTeal,
                type: NSColor.systemBlue,
                function: NSColor.systemIndigo,
                variable: NSColor.labelColor,
                constant: NSColor.systemOrange,
                attribute: NSColor.systemTeal,
                op: NSColor.systemPink,
                punctuation: NSColor.tertiaryLabelColor
            )
            #else
            return CodePalette(
                keyword: UIColor.systemPurple,
                string: UIColor.systemRed,
                comment: UIColor.secondaryLabel,
                number: UIColor.systemTeal,
                type: UIColor.systemBlue,
                function: UIColor.systemIndigo,
                variable: UIColor.label,
                constant: UIColor.systemOrange,
                attribute: UIColor.systemTeal,
                op: UIColor.systemPink,
                punctuation: UIColor.tertiaryLabel
            )
            #endif
        }
    }

    public func codeColor(for tag: HighlightTag) -> PlatformColor? {
        switch tag {
        case .keyword: return codePalette.keyword
        case .string, .stringEscape: return codePalette.string
        case .comment: return codePalette.comment
        case .number, .boolean: return codePalette.number
        case .type: return codePalette.type
        case .function, .method: return codePalette.function
        case .variable, .parameter, .label: return codePalette.variable
        case .constant: return codePalette.constant
        case .attribute, .property, .tag: return codePalette.attribute
        case .op: return codePalette.op
        case .punctuationDelimiter, .punctuationBracket, .punctuationSpecial:
            return codePalette.punctuation
        case .textTitle, .textLiteral, .textEmphasis, .textStrong,
             .textURI, .textReference, .none, .unknown:
            return nil
        }
    }

    /// Per-component colors for rendered pipe tables.
    public struct TablePalette: Equatable {
        /// Background tint stripe behind the header row.
        public var headerBackground: PlatformColor
        /// Background tint for every other body row (zebra striping).
        public var bodyAltBackground: PlatformColor
        /// Stroke color for the rounded outer border of the table.
        public var border: PlatformColor
        /// Stroke color for the thin separator lines between rows and
        /// columns. Usually the same as `border`, but can be tinted lighter
        /// when a theme wants the outer border to read more strongly than
        /// the inner grid.
        public var separator: PlatformColor
        /// Color of the small "raw / rendered" toggle drawn in the table's
        /// top-right corner.
        public var toggle: PlatformColor

        public init(
            headerBackground: PlatformColor,
            bodyAltBackground: PlatformColor,
            border: PlatformColor,
            separator: PlatformColor,
            toggle: PlatformColor
        ) {
            self.headerBackground = headerBackground
            self.bodyAltBackground = bodyAltBackground
            self.border = border
            self.separator = separator
            self.toggle = toggle
        }

        public static var `default`: TablePalette {
            #if canImport(AppKit) && os(macOS)
            return TablePalette(
                headerBackground: NSColor.tertiaryLabelColor.withAlphaComponent(0.08),
                bodyAltBackground: NSColor.tertiaryLabelColor.withAlphaComponent(0.04),
                border: NSColor.tertiaryLabelColor.withAlphaComponent(0.45),
                separator: NSColor.tertiaryLabelColor.withAlphaComponent(0.30),
                toggle: NSColor.secondaryLabelColor
            )
            #else
            return TablePalette(
                headerBackground: UIColor.tertiaryLabel.withAlphaComponent(0.08),
                bodyAltBackground: UIColor.tertiaryLabel.withAlphaComponent(0.04),
                border: UIColor.tertiaryLabel.withAlphaComponent(0.45),
                separator: UIColor.tertiaryLabel.withAlphaComponent(0.30),
                toggle: UIColor.secondaryLabel
            )
            #endif
        }
    }

    public static func `default`(fontScale: CGFloat) -> ProseTheme {
        let baseSize = PlatformFont.systemFontSize * max(fontScale, 0.1)
        let body = PlatformFont.systemFont(ofSize: baseSize)
        let mono = PlatformFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
        #if canImport(AppKit) && os(macOS)
        return ProseTheme(
            bodyFont: body,
            monospaceFont: mono,
            foregroundColor: .labelColor,
            markupColor: .tertiaryLabelColor,
            linkColor: .linkColor,
            linkURLColor: NSColor.secondaryLabelColor,
            blockquoteBarColor: NSColor.tertiaryLabelColor
        )
        #else
        return ProseTheme(
            bodyFont: body,
            monospaceFont: mono,
            foregroundColor: .label,
            markupColor: .tertiaryLabel,
            linkColor: .link,
            linkURLColor: UIColor.secondaryLabel,
            blockquoteBarColor: .tertiaryLabel
        )
        #endif
    }
}
