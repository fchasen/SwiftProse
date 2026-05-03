import Foundation
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

    public init(
        bodyFont: PlatformFont,
        monospaceFont: PlatformFont,
        foregroundColor: PlatformColor,
        markupColor: PlatformColor,
        linkColor: PlatformColor,
        linkURLColor: PlatformColor,
        blockquoteBarColor: PlatformColor,
        headingScale: [Int: CGFloat] = [1: 1.6, 2: 1.4, 3: 1.25, 4: 1.15, 5: 1.05, 6: 1.0]
    ) {
        self.bodyFont = bodyFont
        self.monospaceFont = monospaceFont
        self.foregroundColor = foregroundColor
        self.markupColor = markupColor
        self.linkColor = linkColor
        self.linkURLColor = linkURLColor
        self.blockquoteBarColor = blockquoteBarColor
        self.headingScale = headingScale
    }

    public static var `default`: ProseTheme {
        Self.default(fontScale: 1.0)
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
