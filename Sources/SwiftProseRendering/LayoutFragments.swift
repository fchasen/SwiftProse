#if canImport(AppKit) && os(macOS)
import AppKit
public typealias PlatformLayoutFragment = NSTextLayoutFragment
#elseif canImport(UIKit)
import UIKit
public typealias PlatformLayoutFragment = NSTextLayoutFragment
#else
import Foundation
public typealias PlatformLayoutFragment = NSTextLayoutFragment
#endif

import CoreGraphics
import SwiftProseSyntax

/// Paints a vertical sidebar bar on the left of every blockquote line.
public final class BlockquoteLayoutFragment: NSTextLayoutFragment {
    public var barColor: PlatformColor = .blockquoteDefaultBar
    public var barWidth: CGFloat = 3
    public var barInset: CGFloat = 1
    public var isFirstInRun: Bool = true
    public var isLastInRun: Bool = true

    public override func draw(at point: CGPoint, in context: CGContext) {
        let lines = textLineFragments
        let bounds = layoutFragmentFrame
        let topY: CGFloat
        if isFirstInRun, let first = lines.first {
            topY = first.typographicBounds.minY
        } else {
            topY = 0
        }
        let bottomY: CGFloat
        if isLastInRun, let last = lines.last {
            bottomY = last.typographicBounds.maxY
        } else {
            bottomY = bounds.height
        }
        let height = max(0, bottomY - topY)
        // layoutFragmentFrame.origin.x bakes in lineFragmentPadding +
        // firstLineHeadIndent, so cancel it out to anchor the bar to the
        // container's leading edge instead of the paragraph's text edge.
        let barX = barInset - bounds.origin.x
        let barRect = CGRect(x: barX, y: topY, width: barWidth, height: height)

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.setFillColor(barColor.cgColor)
        context.fill(barRect)
        context.restoreGState()

        super.draw(at: point, in: context)
    }

    public override var renderingSurfaceBounds: CGRect {
        // The bar is painted to the *left* of `layoutFragmentFrame`
        // (`barX = barInset - bounds.origin.x`). Without extending the
        // surface bounds, TextKit's redraw invalidation may clip the bar
        // or treat the fragment as un-dirty when the bar still needs
        // repainting.
        let typographic = super.renderingSurfaceBounds
        let leftOverhang = max(0, layoutFragmentFrame.origin.x - barInset)
        return CGRect(
            x: typographic.minX - leftOverhang,
            y: typographic.minY,
            width: typographic.width + leftOverhang,
            height: typographic.height
        )
    }
}

/// Marker base class used by the layout manager delegate to flag a line
/// fragment as belonging to a code block. The host text view paints code
/// block BGs in one continuous run via a `CAShapeLayer` — going through
/// per-fragment `draw` skipped empty paragraph fragments under TextKit 2,
/// leaving visible gaps inside a multi-line block. Subclasses still own
/// inline chrome painted on top of the band (language tag).
public class CodeBlockLayoutFragment: NSTextLayoutFragment {
    public var horizontalInset: CGFloat = 0
    public var horizontalPadding: CGFloat = 8
    /// Width (in container coordinates) the fill should span.
    public var containerWidth: CGFloat = 0
    /// Right-edge breathing room reserved for the scrollbar gutter.
    public var trailingInset: CGFloat = 0
    /// Symmetric vertical breathing room above and below the line fragments,
    /// applied by the host text view's BG band painter.
    public var verticalPadding: CGFloat = 4
    public var isFirstLine: Bool = false
    public var isLastLine: Bool = false
    /// Background color drawn behind the code-block band. Set by the
    /// layout-manager delegate from the active theme.
    public var fillColor: PlatformColor = .codeBlockDefaultFill

    fileprivate func effectiveWidth(bounds: CGRect) -> CGFloat {
        // Read live container width so the fill reflects the editor's
        // current size — the cached `containerWidth` set at fragment
        // creation goes stale across resizes.
        if let live = textLayoutManager?.textContainer?.size.width, live > 0 {
            return live
        }
        if containerWidth > 0 { return containerWidth }
        return bounds.width
    }
}

/// Same chrome as `CodeBlockLayoutFragment`, plus an optional language tag in
/// the top-right corner of the first fragment in a fenced block.
public final class FencedCodeBlockLayoutFragment: CodeBlockLayoutFragment {
    public var language: String?
    public var languageTagColor: PlatformColor = .codeBlockDefaultTag
    public var languageTagInset: CGFloat = 6

    public override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard isFirstLine, let language, !language.isEmpty else { return }
        let bounds = layoutFragmentFrame
        let width = effectiveWidth(bounds: bounds)
        let firstLine = textLineFragments.first?.typographicBounds
        let lineMinY = firstLine?.minY ?? 0
        let lineMaxY = firstLine?.maxY ?? bounds.height
        let rect = CGRect(
            x: horizontalInset - bounds.origin.x,
            y: lineMinY,
            width: max(0, width - 2 * horizontalInset - trailingInset),
            height: lineMaxY - lineMinY
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: codeBlockTagFont(),
            .foregroundColor: languageTagColor
        ]
        let string = language as NSString
        let size = string.size(withAttributes: attrs)
        let origin = CGPoint(
            x: rect.maxX - size.width - languageTagInset,
            y: rect.minY + (rect.height - size.height) / 2
        )
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        #if canImport(AppKit) && os(macOS)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: layoutFragmentFrame.height > 0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        string.draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        #else
        string.draw(at: origin, withAttributes: attrs)
        #endif
        context.restoreGState()
    }
}

public final class IndentedCodeBlockLayoutFragment: CodeBlockLayoutFragment {}

private func codeBlockTagFont() -> PlatformFont {
    #if canImport(AppKit) && os(macOS)
    return NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    #else
    return UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    #endif
}

extension PlatformColor {
    static var blockquoteDefaultBar: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor
        #else
        return UIColor.tertiaryLabel
        #endif
    }

    static var horizontalRuleDefault: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor
        #else
        return UIColor.tertiaryLabel
        #endif
    }

    public static var codeBlockDefaultFill: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.08)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.08)
        #endif
    }

    static var codeBlockDefaultTag: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.secondaryLabelColor
        #else
        return UIColor.secondaryLabel
        #endif
    }
}
