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

        // Inline code pills layer above the blockquote bar but below glyphs.
        InlineCodePainter.paint(fragment: self, at: point, in: context)
        super.draw(at: point, in: context)
    }
}

/// Replaces the visible `---` / `***` of a thematic break with a thin
/// horizontal rule painted across the available width.
public final class HorizontalRuleLayoutFragment: NSTextLayoutFragment {
    public var ruleColor: PlatformColor = .horizontalRuleDefault
    public var ruleHeight: CGFloat = 1

    public override func draw(at point: CGPoint, in context: CGContext) {
        let bounds = layoutFragmentFrame
        let lineY = bounds.height / 2 - ruleHeight / 2
        let lineRect = CGRect(
            x: 0,
            y: lineY,
            width: bounds.width,
            height: ruleHeight
        )

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.setFillColor(ruleColor.cgColor)
        context.fill(lineRect)
        context.restoreGState()
        // Don't call super — we don't want the literal "---" text to draw.
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

/// Default paragraph fragment that paints a padded rounded "pill" backdrop
/// behind any inline run carrying `.proseInline = .codeSpan`. The
/// attributed-string `.backgroundColor` attribute paints flush against the
/// glyphs which reads as a tight box; we want a chip-style rect with
/// horizontal padding extending past the first and last glyph. Drawn before
/// `super.draw` so glyphs render on top of the fill.
public final class InlineCodePainterLayoutFragment: NSTextLayoutFragment {
    public override func draw(at point: CGPoint, in context: CGContext) {
        InlineCodePainter.paint(fragment: self, at: point, in: context)
        super.draw(at: point, in: context)
    }
}

/// Shared inline-code-pill painter used by `InlineCodePainterLayoutFragment`
/// and `BlockquoteLayoutFragment` (so inline `` `code` `` inside a quote
/// keeps its rounded backdrop too). All routines are stateless; a fragment
/// just hands itself in.
public enum InlineCodePainter {
    public static var fillColor: PlatformColor = .codeBlockDefaultFill
    public static var cornerRadius: CGFloat = 4
    public static var horizontalPadding: CGFloat = 4

    public static func paint(
        fragment: NSTextLayoutFragment,
        at point: CGPoint,
        in context: CGContext
    ) {
        guard let cs = fragment.textLayoutManager?.textContentManager as? NSTextContentStorage,
              let storage = cs.textStorage else { return }
        let elementStart = cs.offset(from: cs.documentRange.location, to: fragment.rangeInElement.location)
        guard elementStart >= 0 else { return }
        let lineFragments = fragment.textLineFragments
        guard !lineFragments.isEmpty else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.setFillColor(fillColor.cgColor)
        for line in lineFragments {
            paintCodeRanges(in: line, storage: storage, elementStart: elementStart, context: context)
        }
        context.restoreGState()
    }

    /// Walk codeSpan runs inside `line` and draw a rounded backdrop behind
    /// each. `line.characterRange` is local to the layout fragment, so add
    /// `elementStart` to land at the right offset in `storage`.
    private static func paintCodeRanges(
        in line: NSTextLineFragment,
        storage: NSTextStorage,
        elementStart: Int,
        context: CGContext
    ) {
        let lineLocal = line.characterRange
        guard lineLocal.length > 0 else { return }
        let storageStart = elementStart + lineLocal.location
        let storageEnd = min(storage.length, storageStart + lineLocal.length)
        guard storageStart < storageEnd else { return }
        var cursor = storageStart
        while cursor < storageEnd {
            var runRange = NSRange(location: cursor, length: 0)
            let value = storage.attribute(
                .proseInline,
                at: cursor,
                longestEffectiveRange: &runRange,
                in: NSRange(location: cursor, length: storageEnd - cursor)
            )
            let runEnd = runRange.location + runRange.length
            if let tag = value as? InlineTag, tag == .codeSpan, runRange.length > 0 {
                let lineRunStart = max(runRange.location, storageStart) - elementStart
                let lineRunEnd = min(runEnd, storageEnd) - elementStart
                let runInLine = NSRange(location: lineRunStart, length: lineRunEnd - lineRunStart)
                drawPill(line: line, runInLine: runInLine, context: context)
            }
            cursor = max(runEnd, cursor + 1)
        }
    }

    private static func drawPill(
        line: NSTextLineFragment,
        runInLine: NSRange,
        context: CGContext
    ) {
        // `runInLine` is layout-fragment-local; the line fragment's character
        // API expects offsets into its own attributedString (zero at the
        // line's first char), so subtract the line's start.
        let localStart = runInLine.location - line.characterRange.location
        let localEndExclusive = localStart + runInLine.length
        guard localStart >= 0,
              localEndExclusive <= line.attributedString.length,
              localStart < localEndExclusive else { return }
        let startPoint = line.locationForCharacter(at: localStart)
        let endPoint = line.locationForCharacter(at: localEndExclusive)
        let bounds = line.typographicBounds
        // locationForCharacter returns a point on the baseline; use the line
        // fragment's typographicBounds for vertical extent.
        let xMin = min(startPoint.x, endPoint.x) - horizontalPadding
        let xMax = max(startPoint.x, endPoint.x) + horizontalPadding
        let pill = CGRect(
            x: bounds.origin.x + xMin,
            y: bounds.origin.y,
            width: max(0, xMax - xMin),
            height: bounds.height
        )
        let path = roundedPath(
            rect: pill,
            topLeft: cornerRadius,
            topRight: cornerRadius,
            bottomLeft: cornerRadius,
            bottomRight: cornerRadius
        )
        context.addPath(path)
        context.fillPath()
    }
}

private func codeBlockTagFont() -> PlatformFont {
    #if canImport(AppKit) && os(macOS)
    return NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    #else
    return UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    #endif
}

private func roundedPath(
    rect: CGRect,
    topLeft: CGFloat,
    topRight: CGFloat,
    bottomLeft: CGFloat,
    bottomRight: CGFloat
) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
    if topRight > 0 {
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight,
            startAngle: -.pi / 2,
            endAngle: 0,
            clockwise: false
        )
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
    if bottomRight > 0 {
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
            radius: bottomRight,
            startAngle: 0,
            endAngle: .pi / 2,
            clockwise: false
        )
    }
    path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
    if bottomLeft > 0 {
        path.addArc(
            center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
            radius: bottomLeft,
            startAngle: .pi / 2,
            endAngle: .pi,
            clockwise: false
        )
    }
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
    if topLeft > 0 {
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft,
            startAngle: .pi,
            endAngle: 3 * .pi / 2,
            clockwise: false
        )
    }
    path.closeSubpath()
    return path
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
