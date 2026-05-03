import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Builds an `NSTextAttachment` whose backing view is a SwiftUI-styled "chip"
/// (rounded pill with a label and SF Symbol) for inline rich content.
///
/// The host wires `MarginaliaInlineContent` through
/// `.inlineContentProvider(_:)`; Marginalia turns each one into one
/// of these attachments.
public enum ChipAttachment {
    public static func make(for content: MarginaliaInlineContent) -> NSTextAttachment {
        let label: String
        let symbolName: String
        switch content {
        case let .url(_, l):
            label = l ?? "link"
            symbolName = "link"
        case let .bugLink(id, l):
            label = l.isEmpty ? "bug \(id)" : l
            symbolName = "ant"
        case let .userMention(handle, displayName):
            label = displayName ?? handle
            symbolName = "person.crop.circle"
        case let .searchfoxLink(_, l, sym):
            label = sym ?? l
            symbolName = "magnifyingglass"
        }

        let attachment = ChipTextAttachment()
        attachment.chipLabel = label
        attachment.chipSymbol = symbolName
        attachment.content = content
        return attachment
    }
}

/// `NSTextAttachment` that knows how to draw itself as a pill with a label
/// and a leading SF Symbol. Drawing is done via `image(forBounds:textContainer:characterIndex:)`
/// because `NSTextAttachmentViewProvider` is more involved and only buys us
/// an interactive subview — a flat rendering is sufficient for MVP.
public final class ChipTextAttachment: NSTextAttachment {
    public var chipLabel: String = ""
    public var chipSymbol: String = "link"
    public var content: MarginaliaInlineContent?

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

#if canImport(AppKit) && os(macOS)
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
public typealias PlatformImage = UIImage
#endif

extension ChipAttachment {
    static func width(for label: String, symbolName: String, height: CGFloat) -> CGFloat {
        let labelWidth = (label as NSString).size(withAttributes: [
            .font: ChipAttachment.chipFont(height: height)
        ]).width
        return labelWidth + height + 14   // symbol + padding
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

        let attrs: [NSAttributedString.Key: Any] = [
            .font: chipFont(height: rect.height),
            .foregroundColor: chipForegroundColor
        ]
        let labelOrigin = CGPoint(x: rect.minX + rect.height + 4, y: rect.minY + (rect.height - chipFont(height: rect.height).pointSize) / 2 - 1)
        (label as NSString).draw(at: labelOrigin, withAttributes: attrs)
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
typealias PlatformBezierPath = NSBezierPath
extension NSBezierPath {
    static func roundedRect(rect: CGRect, cornerRadius: CGFloat) -> NSBezierPath {
        chipPath(rect: rect, cornerRadius: cornerRadius)
    }
}
#elseif canImport(UIKit)
typealias PlatformBezierPath = UIBezierPath
extension UIBezierPath {
    static func roundedRect(rect: CGRect, cornerRadius: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
    }
}
#endif
