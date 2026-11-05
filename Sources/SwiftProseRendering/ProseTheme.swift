import SwiftProseSyntax
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct ProseTheme: Equatable {
    public var bodyFont: PlatformFont
    public var monospaceFont: PlatformFont
    public var foregroundColor: PlatformColor
    public var linkColor: PlatformColor
    public var blockquote: BlockquoteStyle
    public var horizontalRule: HorizontalRuleStyle
    public var codeBlock: CodeBlockStyle
    public var headingScale: [Int: CGFloat]
    public var headingWeights: [Int: PlatformFont.Weight]?
    public var headingFonts: [Int: PlatformFont]?
    public var lineHeightMultiple: CGFloat
    public var textContainerInset: CGSize
    public var tablePalette: TablePalette
    public var source: SourceStyle

    public init(
        bodyFont: PlatformFont,
        monospaceFont: PlatformFont,
        foregroundColor: PlatformColor,
        linkColor: PlatformColor,
        blockquote: BlockquoteStyle = .default,
        horizontalRule: HorizontalRuleStyle = .default,
        codeBlock: CodeBlockStyle = .default,
        headingScale: [Int: CGFloat] = [1: 1.6, 2: 1.4, 3: 1.25, 4: 1.15, 5: 1.05, 6: 1.0],
        headingWeights: [Int: PlatformFont.Weight]? = nil,
        headingFonts: [Int: PlatformFont]? = nil,
        lineHeightMultiple: CGFloat = 1.0,
        textContainerInset: CGSize = CGSize(width: 8, height: 8),
        tablePalette: TablePalette = .default,
        source: SourceStyle = .default
    ) {
        self.bodyFont = bodyFont
        self.monospaceFont = monospaceFont
        self.foregroundColor = foregroundColor
        self.linkColor = linkColor
        self.blockquote = blockquote
        self.horizontalRule = horizontalRule
        self.codeBlock = codeBlock
        self.headingScale = headingScale
        self.headingWeights = headingWeights
        self.headingFonts = headingFonts
        self.lineHeightMultiple = lineHeightMultiple
        self.textContainerInset = textContainerInset
        self.tablePalette = tablePalette
        self.source = source
    }

    public static var `default`: ProseTheme {
        Self.default(fontScale: 1.0)
    }

    public func plainParagraphAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: foregroundColor,
            .paragraphStyle: defaultParagraphStyle(),
            .markdownBlock: MarkdownBlock.paragraph
        ]
    }

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
        return bodyFont.withFontTraits(.bold, scale: scale)
    }

    public struct TablePalette: Equatable {
        public var headerBackground: PlatformColor
        public var bodyAltBackground: PlatformColor
        public var border: PlatformColor
        public var separator: PlatformColor

        public init(
            headerBackground: PlatformColor,
            bodyAltBackground: PlatformColor,
            border: PlatformColor,
            separator: PlatformColor
        ) {
            self.headerBackground = headerBackground
            self.bodyAltBackground = bodyAltBackground
            self.border = border
            self.separator = separator
        }

        public static var `default`: TablePalette {
            #if canImport(AppKit) && os(macOS)
            return TablePalette(
                headerBackground: NSColor.tertiaryLabelColor.withAlphaComponent(0.08),
                bodyAltBackground: NSColor.tertiaryLabelColor.withAlphaComponent(0.04),
                border: NSColor.tertiaryLabelColor.withAlphaComponent(0.45),
                separator: NSColor.tertiaryLabelColor.withAlphaComponent(0.30)
            )
            #else
            return TablePalette(
                headerBackground: UIColor.tertiaryLabel.withAlphaComponent(0.08),
                bodyAltBackground: UIColor.tertiaryLabel.withAlphaComponent(0.04),
                border: UIColor.tertiaryLabel.withAlphaComponent(0.45),
                separator: UIColor.tertiaryLabel.withAlphaComponent(0.30)
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
            linkColor: .linkColor
        )
        #else
        return ProseTheme(
            bodyFont: body,
            monospaceFont: mono,
            foregroundColor: .label,
            linkColor: .link
        )
        #endif
    }
}

public struct BlockquoteStyle: Equatable {
    public var barColor: PlatformColor
    public var textColor: PlatformColor?
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

public struct HorizontalRuleStyle: Equatable {
    public var color: PlatformColor
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

public struct CodeBlockStyle: Equatable {
    public var fillColor: PlatformColor
    public var textColor: PlatformColor?
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

public struct SourceStyle: Equatable {
    public var syntaxColor: PlatformColor
    public var headingColor: PlatformColor
    public var urlColor: PlatformColor
    public var codeColor: PlatformColor
    public var htmlColor: PlatformColor
    public var quoteColor: PlatformColor

    public init(
        syntaxColor: PlatformColor,
        headingColor: PlatformColor,
        urlColor: PlatformColor,
        codeColor: PlatformColor,
        htmlColor: PlatformColor,
        quoteColor: PlatformColor
    ) {
        self.syntaxColor = syntaxColor
        self.headingColor = headingColor
        self.urlColor = urlColor
        self.codeColor = codeColor
        self.htmlColor = htmlColor
        self.quoteColor = quoteColor
    }

    public static var `default`: SourceStyle {
        #if canImport(AppKit) && os(macOS)
        return SourceStyle(
            syntaxColor: .secondaryLabelColor,
            headingColor: .labelColor,
            urlColor: .secondaryLabelColor,
            codeColor: .systemPink,
            htmlColor: .systemPurple,
            quoteColor: .secondaryLabelColor
        )
        #else
        return SourceStyle(
            syntaxColor: .secondaryLabel,
            headingColor: .label,
            urlColor: .secondaryLabel,
            codeColor: .systemPink,
            htmlColor: .systemPurple,
            quoteColor: .secondaryLabel
        )
        #endif
    }
}

extension HTMLBlockAttachment {
    public func apply(theme: ProseTheme) {
        font = theme.bodyFont
        monospaceFont = theme.monospaceFont
        textColor = theme.foregroundColor
        fillColor = theme.codeBlock.fillColor
    }
}
