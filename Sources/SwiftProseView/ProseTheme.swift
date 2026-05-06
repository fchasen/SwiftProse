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
    public var blockquote: BlockquoteStyle
    public var horizontalRule: HorizontalRuleStyle
    public var codeBlock: CodeBlockStyle
    public var headingScale: [Int: CGFloat]
    /// Per-level weight for headings. `nil` (the default) applies the
    /// bold trait to `bodyFont`. When set, the heading font is derived
    /// from `bodyFont`'s family at the given weight — system fonts use
    /// `systemFont(ofSize:weight:)`; named families look up a face via
    /// the descriptor's weight trait, falling back to the bold trait if
    /// no matching face exists. Use `headingFonts` instead when you need
    /// to pin an exact font face per level.
    public var headingWeights: [Int: PlatformFont.Weight]?
    /// Explicit per-level font override. Wins over `headingWeights` and
    /// `headingScale` when set for a level. Use this when working with a
    /// custom typeface whose weights don't map cleanly onto the
    /// system-font weight scale, or when you want a heading face from a
    /// different family than the body.
    public var headingFonts: [Int: PlatformFont]?
    /// Multiplier for every paragraph's natural line height. `1.0`
    /// (the default) is system metrics; `1.4` opens up long-form prose.
    public var lineHeightMultiple: CGFloat
    /// Padding inside the editor's text view, between the text container
    /// and the view's edges. Defaults to 8×8 — the same as a vanilla
    /// NSTextView/UITextView.
    public var textContainerInset: CGSize
    public var codePalette: CodePalette
    public var tablePalette: TablePalette

    public init(
        bodyFont: PlatformFont,
        monospaceFont: PlatformFont,
        foregroundColor: PlatformColor,
        markupColor: PlatformColor,
        linkColor: PlatformColor,
        linkURLColor: PlatformColor,
        blockquote: BlockquoteStyle = .default,
        horizontalRule: HorizontalRuleStyle = .default,
        codeBlock: CodeBlockStyle = .default,
        headingScale: [Int: CGFloat] = [1: 1.6, 2: 1.4, 3: 1.25, 4: 1.15, 5: 1.05, 6: 1.0],
        headingWeights: [Int: PlatformFont.Weight]? = nil,
        headingFonts: [Int: PlatformFont]? = nil,
        lineHeightMultiple: CGFloat = 1.0,
        textContainerInset: CGSize = CGSize(width: 8, height: 8),
        codePalette: CodePalette = .default,
        tablePalette: TablePalette = .default
    ) {
        self.bodyFont = bodyFont
        self.monospaceFont = monospaceFont
        self.foregroundColor = foregroundColor
        self.markupColor = markupColor
        self.linkColor = linkColor
        self.linkURLColor = linkURLColor
        self.blockquote = blockquote
        self.horizontalRule = horizontalRule
        self.codeBlock = codeBlock
        self.headingScale = headingScale
        self.headingWeights = headingWeights
        self.headingFonts = headingFonts
        self.lineHeightMultiple = lineHeightMultiple
        self.textContainerInset = textContainerInset
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
            .paragraphStyle: defaultParagraphStyle(),
            .proseNodePath: NodePathBox(NodePath.fromBlockSpec(.paragraph))
        ]
    }

    /// A paragraph style preconfigured with this theme's
    /// `lineHeightMultiple`. Use as a base when the editor needs to stamp
    /// a "default" style — list bullets, heading reset, etc.
    public func defaultParagraphStyle() -> NSParagraphStyle {
        guard lineHeightMultiple != 1.0 else { return NSParagraphStyle() }
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        return style.copy() as? NSParagraphStyle ?? NSParagraphStyle()
    }

    public func headingFont(level: Int) -> PlatformFont {
        let clamped = max(1, min(6, level))
        if let explicit = headingFonts?[clamped] { return explicit }
        let scale = headingScale[clamped] ?? 1.0
        if let weight = headingWeights?[clamped] {
            return bodyFont.withWeight(weight, size: bodyFont.pointSize * scale)
        }
        return bodyFont.withProseTraits(.bold, scale: scale)
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
        case .textTitle, .textLiteral, .textEmphasis, .textStrong, .textStrike,
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
            linkURLColor: NSColor.secondaryLabelColor
        )
        #else
        return ProseTheme(
            bodyFont: body,
            monospaceFont: mono,
            foregroundColor: .label,
            markupColor: .tertiaryLabel,
            linkColor: .link,
            linkURLColor: UIColor.secondaryLabel
        )
        #endif
    }
}

/// Visual styling for blockquote blocks. Combines the left-side bar
/// ornament with optional overrides for text inside the blockquote
/// scope. Co-locating the knobs reflects the way blockquote styling is
/// authored: the bar and the inner text styling are co-equal axes of
/// the same design decision.
public struct BlockquoteStyle: Equatable {
    /// Color of the left side bar ornament.
    public var barColor: PlatformColor
    /// Foreground color for text inside the blockquote scope. `nil`
    /// inherits `ProseTheme.foregroundColor`.
    public var textColor: PlatformColor?
    /// Font traits layered onto the body font for text inside the
    /// blockquote scope (typically `.italic` for the classic
    /// convention, but consumers can choose any combination).
    public var textTraits: FontTraits

    public init(
        barColor: PlatformColor,
        textColor: PlatformColor? = nil,
        textTraits: FontTraits = []
    ) {
        self.barColor = barColor
        self.textColor = textColor
        self.textTraits = textTraits
    }

    public static var `default`: BlockquoteStyle {
        #if canImport(AppKit) && os(macOS)
        return BlockquoteStyle(barColor: .tertiaryLabelColor)
        #else
        return BlockquoteStyle(barColor: .tertiaryLabel)
        #endif
    }
}

/// Visual styling for thematic breaks (`---` / `***` / `___`).
public struct HorizontalRuleStyle: Equatable {
    /// Stroke color of the rule.
    public var color: PlatformColor
    /// Rule line thickness, in points.
    public var thickness: CGFloat

    public init(color: PlatformColor, thickness: CGFloat = 1) {
        self.color = color
        self.thickness = thickness
    }

    public static var `default`: HorizontalRuleStyle {
        #if canImport(AppKit) && os(macOS)
        return HorizontalRuleStyle(color: .tertiaryLabelColor)
        #else
        return HorizontalRuleStyle(color: .tertiaryLabel)
        #endif
    }
}

/// Visual styling for fenced and indented code blocks. The `fillColor`
/// applies to both code blocks and inline code-span pills (so the two
/// stay visually unified). `textColor` lets a theme override the
/// foreground inside code blocks — useful when the body foreground is
/// particularly low-contrast against `fillColor`.
public struct CodeBlockStyle: Equatable {
    /// Background fill drawn behind code-block lines and inline
    /// code-span pills.
    public var fillColor: PlatformColor
    /// Foreground for code text. `nil` inherits
    /// `ProseTheme.foregroundColor`.
    public var textColor: PlatformColor?
    /// Color of the language tag drawn in the top-right of a fenced
    /// code block.
    public var languageTagColor: PlatformColor

    public init(
        fillColor: PlatformColor,
        textColor: PlatformColor? = nil,
        languageTagColor: PlatformColor
    ) {
        self.fillColor = fillColor
        self.textColor = textColor
        self.languageTagColor = languageTagColor
    }

    public static var `default`: CodeBlockStyle {
        #if canImport(AppKit) && os(macOS)
        return CodeBlockStyle(
            fillColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.08),
            languageTagColor: NSColor.secondaryLabelColor
        )
        #else
        return CodeBlockStyle(
            fillColor: UIColor.tertiaryLabel.withAlphaComponent(0.08),
            languageTagColor: UIColor.secondaryLabel
        )
        #endif
    }
}
