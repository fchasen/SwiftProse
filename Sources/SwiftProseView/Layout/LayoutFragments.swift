import SwiftProseSyntax
import SwiftProseRendering
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

public class MarkdownLayoutFragment: NSTextLayoutFragment {
    public var barWidth: CGFloat = 3
    public var barInset: CGFloat = 1
    weak var controller: EditorController?
    var fixedDecorations = FragmentDecorations()
    private var cachedDecorations: (generation: Int, decorations: FragmentDecorations)?

    var decorations: FragmentDecorations {
        guard let controller,
              let elementStart = textElement?.elementRange?.location else { return fixedDecorations }
        let generation = controller.decorationCache.generation
        if let cachedDecorations, cachedDecorations.generation == generation { return cachedDecorations.decorations }
        let storage = controller.textContentStorage
        let offset = storage.offset(from: storage.documentRange.location, to: elementStart)
        let decorations = FragmentDecorations.make(paragraphAt: offset, controller: controller)
        cachedDecorations = (generation, decorations)
        return decorations
    }

    public var marker: ListMarker? { decorations.marker }
    public var quoteBars: [QuoteBar] { decorations.quoteBars }
    public var barColor: PlatformColor { decorations.barColor }

    var contentStartX: CGFloat {
        guard let line = textLineFragments.first else { return 0 }
        if decorations.isRightToLeft { return line.typographicBounds.maxX }
        return line.typographicBounds.minX + line.locationForCharacter(at: 0).x
    }

    var lineFragmentPadding: CGFloat {
        textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
    }

    var firstBaseline: CGFloat? {
        guard let line = textLineFragments.first else { return nil }
        return line.typographicBounds.minY + line.glyphOrigin.y
    }

    func markerAnchorX(_ decorations: FragmentDecorations) -> CGFloat {
        let offset = decorations.leadingIndent - decorations.markerIndent
        return decorations.isRightToLeft ? contentStartX + offset : contentStartX - offset
    }

    var markerRect: CGRect? {
        let decorations = decorations
        guard let marker = decorations.marker, let baseline = firstBaseline else { return nil }
        let anchor = markerAnchorX(decorations)
        switch marker.kind {
        case .task:
            return ListMarkerRenderer.taskBoxRect(
                font: marker.font,
                anchorX: anchor,
                baseline: baseline,
                isRightToLeft: decorations.isRightToLeft
            )
        case .bullet, .ordinal:
            let height = marker.font.ascender - marker.font.descender
            let width = Restyler.listIndent - ListMarkerRenderer.gap
            let x = decorations.isRightToLeft ? anchor + ListMarkerRenderer.gap : anchor - Restyler.listIndent
            return CGRect(x: x, y: baseline - marker.font.ascender, width: width, height: height)
        }
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        drawDecorations(decorations, at: point, in: context)
        super.draw(at: point, in: context)
        drawImagelessAttachments(at: point, in: context)
    }

    func drawImagelessAttachments(at point: CGPoint, in context: CGContext) {
        guard let elementStart = textElement?.elementRange?.location,
              let contentManager = textLayoutManager?.textContentManager else { return }
        let textContainer = textLayoutManager?.textContainer
        var drawn: [(PlatformImage, CGRect)] = []
        for line in textLineFragments {
            let string = line.attributedString
            string.enumerateAttribute(.attachment, in: line.characterRange) { value, range, _ in
                guard let attachment = value as? NSTextAttachment, attachment.image == nil,
                      let location = contentManager.location(elementStart, offsetBy: range.location) else { return }
                let frame = frameForTextAttachment(at: location)
                guard frame.width > 0, frame.height > 0,
                      let image = attachment.image(
                        for: CGRect(origin: .zero, size: frame.size),
                        attributes: string.attributes(at: range.location, effectiveRange: nil),
                        location: location,
                        textContainer: textContainer
                      ) else { return }
                drawn.append((image, frame.offsetBy(dx: point.x, dy: point.y)))
            }
        }
        guard !drawn.isEmpty else { return }
        #if canImport(AppKit) && os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for (image, rect) in drawn {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPushContext(context)
        for (image, rect) in drawn {
            image.draw(in: rect)
        }
        UIGraphicsPopContext()
        #endif
    }

    func drawDecorations(_ decorations: FragmentDecorations, at point: CGPoint, in context: CGContext) {
        guard decorations.isDecorated else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        if !decorations.quoteBars.isEmpty {
            context.setFillColor(decorations.barColor.cgColor)
            for rect in quoteBarRects(decorations) {
                context.fill(rect)
            }
        }
        if let marker = decorations.marker, let baseline = firstBaseline {
            ListMarkerRenderer.draw(
                marker,
                anchorX: markerAnchorX(decorations),
                baseline: baseline,
                isRightToLeft: decorations.isRightToLeft,
                in: context
            )
        }
        context.restoreGState()
    }

    func quoteBarRects(_ decorations: FragmentDecorations) -> [CGRect] {
        let bounds = layoutFragmentFrame
        let lines = textLineFragments
        let edge = decorations.leadingIndent + lineFragmentPadding
        let origin = decorations.isRightToLeft ? contentStartX + edge : contentStartX - edge
        return decorations.quoteBars.map { bar in
            let topY = bar.isFirstInRun ? (lines.first?.typographicBounds.minY ?? 0) : 0
            let bottomY = bar.isLastInRun ? (lines.last?.typographicBounds.maxY ?? bounds.height) : bounds.height
            let inset = bar.offset + barInset
            let x = decorations.isRightToLeft ? origin - inset - barWidth : origin + inset
            return CGRect(x: x, y: topY, width: barWidth, height: max(0, bottomY - topY))
        }
    }

    public override var renderingSurfaceBounds: CGRect {
        let typographic = super.renderingSurfaceBounds
        guard fixedDecorations.isDecorated || controller != nil else { return typographic }
        if decorations.isRightToLeft {
            let containerWidth = textLayoutManager?.textContainer?.size.width ?? typographic.maxX
            let maxX = max(typographic.maxX, containerWidth - layoutFragmentFrame.origin.x)
            return CGRect(x: typographic.minX, y: typographic.minY, width: maxX - typographic.minX, height: typographic.height)
        }
        let minX = min(typographic.minX, -layoutFragmentFrame.origin.x)
        return CGRect(x: minX, y: typographic.minY, width: typographic.maxX - minX, height: typographic.height)
    }
}

public class CodeBlockLayoutFragment: MarkdownLayoutFragment {
    public var horizontalInset: CGFloat = 0
    public var horizontalPadding: CGFloat = 8
    public var containerWidth: CGFloat = 0
    public var trailingInset: CGFloat = 0
    public var verticalPadding: CGFloat = 4
    public var isFirstLine: Bool = false
    public var isLastLine: Bool = false
    public var fillColor: PlatformColor = .codeBlockDefaultFill

    fileprivate func effectiveWidth(bounds: CGRect) -> CGFloat {
        if let live = textLayoutManager?.textContainer?.size.width, live > 0 {
            return live
        }
        if containerWidth > 0 { return containerWidth }
        return bounds.width
    }
}

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
            .foregroundColor: controller?.theme.codeBlock.languageTagColor ?? languageTagColor
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


private func codeBlockTagFont() -> PlatformFont {
    #if canImport(AppKit) && os(macOS)
    return NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    #else
    return UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    #endif
}
