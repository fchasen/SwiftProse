import Foundation
import CoreGraphics
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class BulletGlyphAttachment: NSTextAttachment {
    public enum Shape {
        case filledDisc
        case strokedCircle
        case filledSquare
        case strokedSquare

        public static func forLevel(_ level: Int) -> Shape {
            switch ((level % 4) + 4) % 4 {
            case 0: return .filledDisc
            case 1: return .strokedCircle
            case 2: return .filledSquare
            default: return .strokedSquare
            }
        }
    }

    public var level: Int = 0
    public var color: PlatformColor = .placeholderColor
    public var sizeFraction: CGFloat = 0.32
    public var heightFraction: CGFloat = 0.85

    public var shape: Shape { Shape.forLevel(level) }

    public convenience init(level: Int, color: PlatformColor) {
        self.init()
        self.level = level
        self.color = color
        self.image = BulletGlyphAttachment.render(
            shape: Shape.forLevel(level),
            color: color,
            sizeFraction: sizeFraction,
            in: CGSize(width: 16, height: 16)
        )
    }

    public override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let height = lineFrag.height > 0 ? lineFrag.height : 17
        let side = max(8, height * heightFraction)
        // Drop bounds slightly below baseline so the visual glyph centers near
        // the body text's x-height instead of sitting above the cap-height.
        let yOffset = -height * 0.18
        return CGRect(x: 0, y: yOffset, width: side, height: side)
    }

    public override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> PlatformImage? {
        BulletGlyphAttachment.render(shape: shape, color: color, sizeFraction: sizeFraction, in: imageBounds.size)
    }
}

extension PlatformColor {
    fileprivate static var placeholderColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor
        #else
        return UIColor.tertiaryLabel
        #endif
    }
}

extension BulletGlyphAttachment {
    static func render(shape: Shape, color: PlatformColor, sizeFraction: CGFloat, in size: CGSize) -> PlatformImage {
        #if canImport(AppKit) && os(macOS)
        return NSImage(size: size, flipped: true) { rect in
            draw(shape: shape, color: color, sizeFraction: sizeFraction, in: rect)
            return true
        }
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(shape: shape, color: color, sizeFraction: sizeFraction, in: CGRect(origin: .zero, size: size))
        }
        #endif
    }

    static func draw(shape: Shape, color: PlatformColor, sizeFraction: CGFloat, in rect: CGRect) {
        let glyphSide = max(3, min(rect.width, rect.height) * sizeFraction)
        let glyphRect = CGRect(
            x: rect.midX - glyphSide / 2,
            y: rect.midY - glyphSide / 2,
            width: glyphSide,
            height: glyphSide
        )
        let path: PlatformBezierPath
        switch shape {
        case .filledDisc, .strokedCircle:
            #if canImport(AppKit) && os(macOS)
            path = NSBezierPath(ovalIn: glyphRect)
            #else
            path = UIBezierPath(ovalIn: glyphRect)
            #endif
        case .filledSquare, .strokedSquare:
            #if canImport(AppKit) && os(macOS)
            path = NSBezierPath(rect: glyphRect)
            #else
            path = UIBezierPath(rect: glyphRect)
            #endif
        }

        switch shape {
        case .filledDisc, .filledSquare:
            color.setFill()
            path.fill()
        case .strokedCircle, .strokedSquare:
            path.lineWidth = max(1, glyphSide * 0.14)
            color.setStroke()
            path.stroke()
        }
    }
}
