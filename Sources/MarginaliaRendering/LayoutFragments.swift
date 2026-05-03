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
import MarginaliaSyntax

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

/// Paints a tinted, rounded background behind a single line of a fenced code
/// block. Each line of the block is its own layout fragment; `isFirstLine` /
/// `isLastLine` toggle the rounding so consecutive fragments stitch into one
/// block visually.
public class CodeBlockLayoutFragment: NSTextLayoutFragment {
    public var fillColor: PlatformColor = .codeBlockDefaultFill
    public var cornerRadius: CGFloat = 6
    public var horizontalInset: CGFloat = 0
    public var isFirstLine: Bool = false
    public var isLastLine: Bool = false

    public override func draw(at point: CGPoint, in context: CGContext) {
        let bounds = layoutFragmentFrame
        let rect = CGRect(
            x: horizontalInset,
            y: 0,
            width: max(0, bounds.width - 2 * horizontalInset),
            height: bounds.height
        )

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.setFillColor(fillColor.cgColor)
        let path = roundedPath(
            rect: rect,
            topLeft: isFirstLine ? cornerRadius : 0,
            topRight: isFirstLine ? cornerRadius : 0,
            bottomLeft: isLastLine ? cornerRadius : 0,
            bottomRight: isLastLine ? cornerRadius : 0
        )
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        super.draw(at: point, in: context)
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
        let rect = CGRect(
            x: horizontalInset,
            y: 0,
            width: max(0, bounds.width - 2 * horizontalInset),
            height: bounds.height
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

/// Paints cell borders for a pipe table. Each row of the table is its own
/// layout fragment; outer-edge segments are drawn so consecutive fragments
/// stitch into a continuous bordered grid. Internal column borders come from
/// detecting pipe character positions within each line fragment.
public final class PipeTableLayoutFragment: NSTextLayoutFragment {
    public var borderColor: PlatformColor = .pipeTableDefaultBorder
    public var borderWidth: CGFloat = 0.5
    public var horizontalInset: CGFloat = 0
    public var isFirstLine: Bool = false
    public var isLastLine: Bool = false

    public override func draw(at point: CGPoint, in context: CGContext) {
        let bounds = layoutFragmentFrame
        let rect = CGRect(
            x: horizontalInset,
            y: 0,
            width: max(0, bounds.width - 2 * horizontalInset),
            height: bounds.height
        )

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(borderWidth)

        let path = CGMutablePath()
        if isFirstLine {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        for line in textLineFragments {
            let lineBounds = line.typographicBounds
            let s = line.attributedString.string
            var idx = 0
            for ch in s {
                if ch == "|" {
                    let pos = line.locationForCharacter(at: idx)
                    let x = lineBounds.minX + pos.x
                    if x > rect.minX + 0.5, x < rect.maxX - 0.5 {
                        path.move(to: CGPoint(x: x, y: lineBounds.minY))
                        path.addLine(to: CGPoint(x: x, y: lineBounds.maxY))
                    }
                }
                idx += 1
            }
        }

        context.addPath(path)
        context.strokePath()
        context.restoreGState()

        super.draw(at: point, in: context)
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

    static var codeBlockDefaultFill: PlatformColor {
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

    static var pipeTableDefaultBorder: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor
        #else
        return UIColor.tertiaryLabel
        #endif
    }
}
