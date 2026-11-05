import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum ChipAttachment {
    public static func make(for content: ProseInlineContent) -> ChipTextAttachment {
        let label: String
        let symbolName: String
        switch content {
        case let .url(_, l):
            label = l ?? "link"
            symbolName = "link"
        case let .userMention(handle, displayName):
            label = displayName ?? handle
            symbolName = "person.crop.circle"
        case let .custom(_, l, systemImage):
            label = l
            symbolName = systemImage
        }

        let attachment = ChipTextAttachment()
        attachment.chipLabel = label
        attachment.chipSymbol = symbolName
        attachment.content = content
        attachment.contentKind = content.kind
        return attachment
    }

    public static func make(
        label: String,
        systemImage: String,
        markdownSource: String,
        contentKind: String
    ) -> ChipTextAttachment {
        let attachment = ChipTextAttachment()
        attachment.chipLabel = label
        attachment.chipSymbol = systemImage
        attachment.markdownSource = markdownSource
        attachment.contentKind = contentKind
        return attachment
    }
}

public final class ChipTextAttachment: NSTextAttachment, ProseSourceAttachment {
    public var chipLabel: String = ""
    public var chipSymbol: String = "link"
    public var content: ProseInlineContent?
    public var markdownSource: String = ""
    public var contentKind: String = ""

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
        let height = max(lineFrag.height, 18)
        let width = ChipAttachment.width(for: chipLabel, symbolName: chipSymbol, height: height)
        return CGRect(x: 0, y: -2, width: width, height: height)
    }

    public override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> PlatformImage? {
        ChipAttachment.render(label: chipLabel, symbolName: chipSymbol, in: imageBounds.size)
    }
}

extension ChipAttachment {
    static func width(for label: String, symbolName: String, height: CGFloat) -> CGFloat {
        let labelWidth = (label as NSString).size(withAttributes: [
            .font: ChipAttachment.chipFont(height: height)
        ]).width
        return labelWidth + height + 14  
    }

    static func chipFont(height: CGFloat) -> PlatformFont {
        let size = max(11, height - 6)
        #if canImport(AppKit) && os(macOS)
        return NSFont.systemFont(ofSize: size, weight: .medium)
        #else
        return UIFont.systemFont(ofSize: size, weight: .medium)
        #endif
    }

    static func render(label: String, symbolName: String, in size: CGSize) -> PlatformImage {
        #if canImport(AppKit) && os(macOS)
        return NSImage(size: size, flipped: false) { rect in
            ChipAttachment.draw(label: label, symbolName: symbolName, in: rect)
            return true
        }
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ChipAttachment.draw(label: label, symbolName: symbolName, in: CGRect(origin: .zero, size: size))
        }
        #endif
    }

    static func draw(label: String, symbolName: String, in rect: CGRect) {
        let path: PlatformBezierPath
        let radius = rect.height / 2
        path = PlatformBezierPath.roundedRect(rect: rect, cornerRadius: radius)
        chipBackgroundColor.setFill()
        path.fill()

        drawSymbol(symbolName, in: CGRect(x: rect.minX + 2, y: rect.minY, width: rect.height, height: rect.height))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: chipFont(height: rect.height),
            .foregroundColor: chipForegroundColor
        ]
        let labelOrigin = CGPoint(x: rect.minX + rect.height + 4, y: rect.minY + (rect.height - chipFont(height: rect.height).pointSize) / 2 - 1)
        (label as NSString).draw(at: labelOrigin, withAttributes: attrs)
    }

    static func drawSymbol(_ name: String, in rect: CGRect) {
        let pointSize = rect.height * 0.6
        #if canImport(AppKit) && os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [chipForegroundColor]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        #else
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(chipForegroundColor, renderingMode: .alwaysOriginal) else { return }
        #endif
        let size = symbol.size
        symbol.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    static var chipBackgroundColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.controlAccentColor.withAlphaComponent(0.18)
        #else
        return UIColor.tintColor.withAlphaComponent(0.18)
        #endif
    }

    static var chipForegroundColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.controlAccentColor
        #else
        return UIColor.tintColor
        #endif
    }
}

#if canImport(AppKit) && os(macOS)
extension NSBezierPath {
    static func chipPath(rect: CGRect, cornerRadius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    }
}
package typealias PlatformBezierPath = NSBezierPath
extension NSBezierPath {
    package static func roundedRect(rect: CGRect, cornerRadius: CGFloat) -> NSBezierPath {
        chipPath(rect: rect, cornerRadius: cornerRadius)
    }
}
#elseif canImport(UIKit)
package typealias PlatformBezierPath = UIBezierPath
extension UIBezierPath {
    package static func roundedRect(rect: CGRect, cornerRadius: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
    }
}
#endif
