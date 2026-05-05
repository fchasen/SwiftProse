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

/// Renders one source line of a GFM pipe table as a structured cell row.
///
/// In rendered mode we **do not** call `super.draw` — the literal source
/// (pipes, dashes, padding spaces) would render misaligned with the column
/// chrome since cell text in storage doesn't sit at the column boundaries.
/// Instead we draw `attributedCells` (one per column) into rects derived
/// from `columnXs`, honoring per-column alignment and wrapping cell text
/// inside its column. The fragment's `renderingSurfaceBounds` is extended
/// to the full container width so the drawn chrome reaches the right edge
/// and the toggle button at the rightmost extent is reachable by hit-testing.
///
/// In raw mode (`isRawMode == true`) we skip all chrome and call
/// `super.draw` — the user sees the literal source for hand-editing.
public final class PipeTableLayoutFragment: NSTextLayoutFragment {
    public enum LineRole: Equatable {
        case header
        case alignment
        case body
    }

    public var borderColor: PlatformColor = .pipeTableDefaultBorder
    public var separatorColor: PlatformColor = .pipeTableDefaultBorder
    public var borderWidth: CGFloat = 1
    public var headerBackgroundColor: PlatformColor = .pipeTableHeaderDefaultBackground
    public var bodyAltBackgroundColor: PlatformColor = .pipeTableBodyAltDefaultBackground
    public var toggleColor: PlatformColor = .pipeTableToggleDefault
    public var horizontalInset: CGFloat = 0
    public var cellPaddingHorizontal: CGFloat = 14
    public var cellPaddingVertical: CGFloat = 10
    public var cornerRadius: CGFloat = 6
    /// Width (container coords) the chrome should span. Set by
    /// `LayoutManagerDelegate`; defaults to 0 → falls back to `layoutFragmentFrame`.
    public var containerWidth: CGFloat = 0
    public var isFirstLine: Bool = false
    public var isLastLine: Bool = false
    public var role: LineRole = .body
    /// Column boundary x-positions including outer edges, in fragment-local
    /// coordinates. `[xLeft, x1, x2, ..., xRight]` so `count == columnCount + 1`.
    public var columnXs: [CGFloat] = []
    public var isRawMode: Bool = false
    public var bodyRowIndex: Int = 0
    /// Pre-formatted attributed cells with inline decorations applied
    /// (bold/italic/code/link). Index → column.
    public var attributedCells: [NSAttributedString] = []
    /// Per-column horizontal alignment for this row's cells. Empty falls
    /// back to natural (left-leading).
    public var alignments: [PipeTableAlignment] = []
    /// Hit rect for the raw-mode toggle (only painted on first table line),
    /// in fragment-local coordinates.
    public var toggleHitRect: CGRect = .zero

    public override var renderingSurfaceBounds: CGRect {
        let bounds = layoutFragmentFrame
        if isRawMode {
            return super.renderingSurfaceBounds
        }
        let width = max(containerWidth, bounds.width)
        return CGRect(x: -bounds.origin.x, y: 0, width: width, height: bounds.height)
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        if isRawMode {
            super.draw(at: point, in: context)
            return
        }
        let bounds = layoutFragmentFrame
        let width = max(containerWidth, bounds.width)
        let rect = CGRect(
            x: horizontalInset - bounds.origin.x,
            y: 0,
            width: max(0, width - 2 * horizontalInset),
            height: bounds.height
        )

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)

        let topLeft = isFirstLine ? cornerRadius : 0
        let topRight = isFirstLine ? cornerRadius : 0
        let bottomLeft = isLastLine ? cornerRadius : 0
        let bottomRight = isLastLine ? cornerRadius : 0

        // Row background fill (rounded only on the outer table edges so
        // mid-table fragments stitch into a flat-edged stripe).
        if let fill = rowFillColor() {
            let fillPath = roundedPath(
                rect: rect,
                topLeft: topLeft,
                topRight: topRight,
                bottomLeft: bottomLeft,
                bottomRight: bottomRight
            )
            context.setFillColor(fill.cgColor)
            context.addPath(fillPath)
            context.fillPath()
        }

        // Vertical column separators — drawn before the outer border so
        // they tuck under the rounded corners visually.
        let xs = columnXs.isEmpty ? [0, rect.width] : columnXs
        if xs.count > 2, role != .alignment {
            context.setStrokeColor(separatorColor.cgColor)
            context.setLineWidth(borderWidth)
            let sep = CGMutablePath()
            for i in 1..<(xs.count - 1) {
                let x = rect.minX + xs[i]
                sep.move(to: CGPoint(x: x, y: rect.minY))
                sep.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            context.addPath(sep)
            context.strokePath()
        }

        // Horizontal row divider between this row and the next. Suppressed
        // on the last row (outer border handles it) and on the alignment
        // row (collapsed to ~1px so the divider would look doubled).
        if !isLastLine, role != .alignment {
            context.setStrokeColor(separatorColor.cgColor)
            context.setLineWidth(borderWidth)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            context.addPath(p)
            context.strokePath()
        }

        // Outer rounded border. Drawn per fragment so consecutive fragments
        // stitch into one continuous border; mid-table fragments contribute
        // only the left and right sides.
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(borderWidth)
        let outer = outerBorderPath(
            rect: rect,
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight
        )
        context.addPath(outer)
        context.strokePath()

        if role != .alignment {
            drawCellText(in: rect, columnXs: xs, context: context)
        }

        if isFirstLine, !toggleHitRect.isEmpty {
            drawToggleIcon(in: toggleHitRect, context: context)
        }

        context.restoreGState()
        // Deliberately skip super.draw — literal source text would
        // misalign with the chrome columns.
    }

    private func rowFillColor() -> PlatformColor? {
        switch role {
        case .header: return headerBackgroundColor
        case .alignment: return nil
        case .body: return (bodyRowIndex % 2 == 1) ? bodyAltBackgroundColor : nil
        }
    }

    /// Build the table's outer border for this fragment: full rounded box
    /// when the table is a single line, top edge + sides + arcs on the
    /// first line, bottom edge + sides + arcs on the last line, just the
    /// vertical sides on mid-table fragments.
    private func outerBorderPath(
        rect: CGRect,
        topLeft: CGFloat,
        topRight: CGFloat,
        bottomLeft: CGFloat,
        bottomRight: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        // Top edge.
        if isFirstLine {
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
        }
        // Right side.
        let rightStart = rect.minY + (isFirstLine ? topRight : 0)
        let rightEnd = rect.maxY - (isLastLine ? bottomRight : 0)
        path.move(to: CGPoint(x: rect.maxX, y: rightStart))
        path.addLine(to: CGPoint(x: rect.maxX, y: rightEnd))
        // Bottom edge.
        if isLastLine {
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
        }
        // Left side.
        let leftEnd = rect.maxY - (isLastLine ? bottomLeft : 0)
        let leftStart = rect.minY + (isFirstLine ? topLeft : 0)
        path.move(to: CGPoint(x: rect.minX, y: leftEnd))
        path.addLine(to: CGPoint(x: rect.minX, y: leftStart))
        if isFirstLine, topLeft > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
                radius: topLeft,
                startAngle: .pi,
                endAngle: 3 * .pi / 2,
                clockwise: false
            )
        }
        return path
    }

    private func drawCellText(in rect: CGRect, columnXs xs: [CGFloat], context: CGContext) {
        guard !attributedCells.isEmpty else { return }
        let columnCount = max(0, xs.count - 1)
        guard columnCount > 0 else { return }
        let drawingOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        for i in 0..<columnCount {
            guard i < attributedCells.count else { continue }
            let cell = attributedCells[i]
            guard cell.length > 0 else { continue }
            let alignment = (i < alignments.count) ? alignments[i] : .none
            let cellRect = CGRect(
                x: rect.minX + xs[i] + cellPaddingHorizontal,
                y: rect.minY + cellPaddingVertical,
                width: max(0, xs[i + 1] - xs[i] - 2 * cellPaddingHorizontal),
                height: max(0, rect.height - 2 * cellPaddingVertical)
            )
            guard cellRect.width > 0, cellRect.height > 0 else { continue }
            let aligned = applyAlignment(cell, alignment: alignment)
            let bounding = aligned.boundingRect(
                with: CGSize(width: cellRect.width, height: .greatestFiniteMagnitude),
                options: drawingOpts,
                context: nil
            )
            // Vertically center the wrapped text block in the cell rect so
            // single-line cells align with multi-line peers.
            let yOrigin = cellRect.minY + max(0, (cellRect.height - bounding.height) / 2)
            let drawRect = CGRect(
                x: cellRect.minX,
                y: yOrigin,
                width: cellRect.width,
                height: max(bounding.height, cellRect.height)
            )
            #if canImport(AppKit) && os(macOS)
            let nsContext = NSGraphicsContext(cgContext: context, flipped: layoutFragmentFrame.height > 0)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            aligned.draw(with: drawRect, options: drawingOpts, context: nil)
            NSGraphicsContext.restoreGraphicsState()
            #else
            aligned.draw(with: drawRect, options: drawingOpts, context: nil)
            #endif
        }
    }

    /// Stamp the cell's paragraph alignment (left/right/center) without
    /// disturbing the existing inline attributes (font, foreground, code-
    /// span backdrop, link styling).
    private func applyAlignment(_ s: NSAttributedString, alignment: PipeTableAlignment) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        switch alignment {
        case .right: para.alignment = .right
        case .center: para.alignment = .center
        case .left, .none: para.alignment = .natural
        }
        para.lineBreakMode = .byWordWrapping
        let mut = NSMutableAttributedString(attributedString: s)
        mut.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: mut.length))
        return mut
    }

    private func drawToggleIcon(in rect: CGRect, context: CGContext) {
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
    /// outside the table's drawn area or in the alignment row.
    public func cellHitTest(at point: CGPoint) -> (row: Int, column: Int)? {
        guard !isRawMode, role != .alignment else { return nil }
        guard !columnXs.isEmpty else { return nil }
        let bounds = layoutFragmentFrame
        guard point.y >= 0, point.y <= bounds.height else { return nil }
        let x = point.x
        var col: Int?
        for i in 0..<(columnXs.count - 1) {
            if x >= columnXs[i], x < columnXs[i + 1] {
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

    static var pipeTableCellTextDefault: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.labelColor
        #else
        return UIColor.label
        #endif
    }

    static var pipeTableBodyAltDefaultBackground: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.05)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.05)
        #endif
    }
}

extension PlatformFont {
    static var pipeTableCellDefaultFont: PlatformFont {
        #if canImport(AppKit) && os(macOS)
        return NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #else
        return UIFont.systemFont(ofSize: UIFont.systemFontSize)
        #endif
    }

    static var pipeTableHeaderDefaultFont: PlatformFont {
        #if canImport(AppKit) && os(macOS)
        return NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        #else
        return UIFont.boldSystemFont(ofSize: UIFont.systemFontSize)
        #endif
    }
}
