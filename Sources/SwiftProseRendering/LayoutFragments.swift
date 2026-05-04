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

/// Paints chrome for one source line of a rendered GFM pipe table.
///
/// One fragment per source line. Vertical column dividers and outer borders
/// are computed from `PipeTableModel.columnXs` (so they line up across rows
/// even when cell text widths differ), not by glyph-hunting `|` positions
/// like the original implementation. The header line gets a tinted backdrop
/// and bold text (the bold is applied by the compiler). The alignment line
/// is suppressed — neither text nor borders are drawn so the literal
/// `:--- | --- | ---:` doesn't appear.
public final class PipeTableLayoutFragment: NSTextLayoutFragment {
    public enum LineRole: Equatable {
        case header
        case alignment
        case body
    }

    public var borderColor: PlatformColor = .pipeTableDefaultBorder
    public var borderWidth: CGFloat = 0.5
    public var headerBackgroundColor: PlatformColor = .pipeTableHeaderDefaultBackground
    public var toggleColor: PlatformColor = .pipeTableToggleDefault
    public var horizontalInset: CGFloat = 0
    public var isFirstLine: Bool = false
    public var isLastLine: Bool = false
    public var role: LineRole = .body
    /// Column boundary x-positions including outer edges, in fragment-local
    /// coordinates. `[xLeft, x1, x2, ..., xRight]` so `count == columnCount + 1`.
    /// When empty, vertical dividers fall back to the bounding rect edges.
    public var columnXs: [CGFloat] = []
    /// True when the table is in the controller's `expandedTablesTracker`
    /// — meaning the user has flipped this table to raw monospace mode and
    /// we should skip ALL chrome and let the literal source draw normally.
    public var isRawMode: Bool = false
    /// Body row index for `role == .body`. Header is `-1`; `.alignment` is
    /// `-2`. Set by the layout manager delegate so cell hit-testing can map
    /// clicks back to the model.
    public var bodyRowIndex: Int = 0
    /// Offset of the toggle button (top-right of the first table line) in
    /// fragment-local coordinates. The host text view reads `toggleHitRect`
    /// and dispatches clicks to the controller.
    public var toggleHitRect: CGRect = .zero

    public override func draw(at point: CGPoint, in context: CGContext) {
        if isRawMode {
            super.draw(at: point, in: context)
            return
        }
        if role == .alignment {
            // Suppress drawing entirely — the literal dashes shouldn't appear
            // and we don't draw borders here either since the alignment row
            // has been collapsed to a near-zero line height by the compiler.
            return
        }

        let bounds = layoutFragmentFrame
        let rect = CGRect(
            x: horizontalInset,
            y: 0,
            width: max(0, bounds.width - 2 * horizontalInset),
            height: bounds.height
        )

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)

        if role == .header {
            context.setFillColor(headerBackgroundColor.cgColor)
            context.fill(rect)
        }

        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(borderWidth)
        let path = CGMutablePath()
        if isFirstLine {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        if isLastLine {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        // Verticals: from columnXs (computed model) so internal dividers line
        // up across rows even when individual cells wrap or differ in width.
        let xs = columnXs.isEmpty ? [rect.minX, rect.maxX] : columnXs
        for x in xs {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        context.addPath(path)
        context.strokePath()

        if isFirstLine, !toggleHitRect.isEmpty {
            drawToggleIcon(in: toggleHitRect, context: context)
        }

        context.restoreGState()
        super.draw(at: point, in: context)
    }

    private func drawToggleIcon(in rect: CGRect, context: CGContext) {
        // Three short stacked horizontal lines — a classic "edit raw" glyph.
        context.setStrokeColor(toggleColor.cgColor)
        context.setLineWidth(1)
        context.setLineCap(.round)
        let lineCount = 3
        let inset: CGFloat = 3
        let usable = rect.insetBy(dx: inset, dy: inset)
        let spacing = usable.height / CGFloat(lineCount + 1)
        for i in 1...lineCount {
            let y = usable.minY + spacing * CGFloat(i)
            context.move(to: CGPoint(x: usable.minX, y: y))
            context.addLine(to: CGPoint(x: usable.maxX, y: y))
        }
        context.strokePath()
    }

    /// Map a click in fragment-local coordinates to a (row, column) cell
    /// index, where `row == -1` denotes the header. Returns nil for clicks
    /// outside the table's drawn area or in the alignment row. Used by the
    /// host text view to surface the cell-edit sheet.
    public func cellHitTest(at point: CGPoint) -> (row: Int, column: Int)? {
        guard !isRawMode, role != .alignment else { return nil }
        guard !columnXs.isEmpty else { return nil }
        let bounds = layoutFragmentFrame
        guard point.y >= 0, point.y <= bounds.height else { return nil }
        var col: Int?
        for i in 0..<(columnXs.count - 1) {
            if point.x >= columnXs[i], point.x < columnXs[i + 1] {
                col = i
                break
            }
        }
        guard let col else { return nil }
        let row = (role == .header) ? -1 : bodyRowIndex
        return (row, col)
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

    static var pipeTableHeaderDefaultBackground: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.10)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.10)
        #endif
    }

    static var pipeTableToggleDefault: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.secondaryLabelColor
        #else
        return UIColor.secondaryLabel
        #endif
    }
}
