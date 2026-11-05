import SwiftProseSyntax
import SwiftProseRendering
import Foundation
import CoreGraphics
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class TableRowLayoutFragment: MarkdownLayoutFragment {
    var palette: ProseTheme.TablePalette = .default
    var fixedGeometry: TableRowGeometry?
    var fixedLeadingIndent: CGFloat = 0
    var isHeader = false

    private var paragraphOffset: Int? {
        guard let controller, let start = textElement?.elementRange?.location else { return nil }
        let storage = controller.textContentStorage
        let offset = storage.offset(from: storage.documentRange.location, to: start)
        guard offset >= 0, offset < controller.textStorage.length else { return nil }
        return offset
    }

    var geometry: TableRowGeometry? {
        guard let controller, let offset = paragraphOffset else { return fixedGeometry }
        return controller.textStorage.attribute(.markdownTableGeometry, at: offset, effectiveRange: nil) as? TableRowGeometry
            ?? fixedGeometry
    }

    private var leadingIndent: CGFloat {
        guard let controller, let offset = paragraphOffset,
              let style = controller.textStorage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
        else { return fixedLeadingIndent }
        return style.firstLineHeadIndent
    }

    var containerLeft: CGFloat {
        contentStartX - leadingIndent - lineFragmentPadding
    }

    func rowRect(_ geometry: TableRowGeometry) -> CGRect? {
        guard let first = geometry.columnEdges.first, let last = geometry.columnEdges.last,
              let firstLine = textLineFragments.first, let lastLine = textLineFragments.last else { return nil }
        let padding = TableMetrics.cellPadding.height
        let left = containerLeft + lineFragmentPadding
        let top = firstLine.typographicBounds.minY - padding
        let bottom = lastLine.typographicBounds.maxY + padding
        return CGRect(x: left + first, y: top, width: last - first, height: bottom - top)
    }

    func columnBoundaries(_ geometry: TableRowGeometry) -> [CGFloat] {
        let left = containerLeft + lineFragmentPadding
        return geometry.columnEdges.map { left + $0 }
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        if let geometry, let rect = rowRect(geometry) {
            drawTable(geometry, rect: rect, at: point, in: context)
        }
        super.draw(at: point, in: context)
    }

    private func drawTable(_ geometry: TableRowGeometry, rect: CGRect, at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        if isHeader {
            context.setFillColor(palette.headerBackground.cgColor)
            context.fill(rect)
        } else if geometry.rowIndex > 0, geometry.rowIndex % 2 == 0 {
            context.setFillColor(palette.bodyAltBackground.cgColor)
            context.fill(rect)
        }
        let boundaries = columnBoundaries(geometry)
        let pixel: CGFloat = 0.5
        context.setLineWidth(1)
        context.setStrokeColor(palette.separator.cgColor)
        for x in boundaries.dropFirst().dropLast() {
            context.move(to: CGPoint(x: x + pixel, y: rect.minY))
            context.addLine(to: CGPoint(x: x + pixel, y: rect.maxY))
        }
        if !geometry.isLast {
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY - pixel))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - pixel))
        }
        context.strokePath()
        context.setStrokeColor(palette.border.cgColor)
        context.move(to: CGPoint(x: rect.minX + pixel, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.minX + pixel, y: rect.maxY))
        context.move(to: CGPoint(x: rect.maxX - pixel, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.maxX - pixel, y: rect.maxY))
        if geometry.isFirst {
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + pixel))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + pixel))
        }
        if geometry.isLast {
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY - pixel))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - pixel))
        }
        context.strokePath()
        context.restoreGState()
    }

    public override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        guard let geometry, let rect = rowRect(geometry) else { return base }
        return base.union(rect.insetBy(dx: -1, dy: -1))
    }
}
