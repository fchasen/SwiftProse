import Foundation
import CoreGraphics
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class HorizontalRuleAttachment: NSTextAttachment, ProseSourceAttachment {
    public var markdownSource: String = "---"
    public var contentKind: String = AtomKind.thematicBreak
    public var color: PlatformColor
    public var thickness: CGFloat
    public var verticalExtent: CGFloat

    public init(color: PlatformColor, thickness: CGFloat = 1, verticalExtent: CGFloat = 24) {
        self.color = color
        self.thickness = thickness
        self.verticalExtent = verticalExtent
        super.init(data: nil, ofType: nil)
    }

    public required init?(coder: NSCoder) {
        self.color = .horizontalRuleDefault
        self.thickness = 1
        self.verticalExtent = 24
        super.init(coder: coder)
    }

    public override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        attachmentBounds(for: textContainer, proposedLineFragment: proposedLineFragment, glyphPosition: position, characterIndex: 0)
    }

    public override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> PlatformImage? {
        image(forBounds: bounds, textContainer: textContainer, characterIndex: 0)
    }

    public override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let width: CGFloat
        if lineFrag.width > 0 {
            width = lineFrag.width
        } else if let cw = textContainer?.size.width,
                  cw > 0,
                  cw < .greatestFiniteMagnitude {
            width = cw
        } else {
            width = 320
        }
        return CGRect(x: 0, y: 0, width: width, height: verticalExtent)
    }

    public override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> PlatformImage? {
        HorizontalRuleAttachment.render(
            color: color,
            thickness: thickness,
            in: imageBounds.size
        )
    }
}

extension HorizontalRuleAttachment {
    static func render(color: PlatformColor, thickness: CGFloat, in size: CGSize) -> PlatformImage {
        #if canImport(AppKit) && os(macOS)
        return NSImage(size: size, flipped: true) { rect in
            draw(color: color, thickness: thickness, in: rect)
            return true
        }
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(color: color, thickness: thickness, in: CGRect(origin: .zero, size: size))
        }
        #endif
    }

    static func draw(color: PlatformColor, thickness: CGFloat, in rect: CGRect) {
        let lineRect = CGRect(
            x: rect.minX,
            y: rect.midY - thickness / 2,
            width: rect.width,
            height: thickness
        )
        color.setFill()
        #if canImport(AppKit) && os(macOS)
        NSBezierPath(rect: lineRect).fill()
        #else
        UIBezierPath(rect: lineRect).fill()
        #endif
    }
}
