import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// `NSTextAttachment` that draws a task-list checkbox sized to the surrounding
/// body font. Replaces the U+2610 / U+2611 unicode glyphs the editor used at
/// first — those rendered tiny and font-dependent. This one is a real square
/// with a stroke, optionally containing a checkmark.
public final class CheckboxAttachment: NSTextAttachment {
    public var isChecked: Bool = false {
        didSet { refreshImage() }
    }
    public var heightFraction: CGFloat = 0.85

    public override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        refreshImage()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        refreshImage()
    }

    private func refreshImage() {
        self.image = CheckboxAttachment.render(checked: isChecked, in: CGSize(width: 16, height: 16))
    }

    public override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let height = lineFrag.height > 0 ? lineFrag.height : 17
        let side = max(10, height * heightFraction)
        let yOffset = -height * 0.18
        return CGRect(x: 0, y: yOffset, width: side, height: side)
    }

    public override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> PlatformImage? {
        CheckboxAttachment.render(checked: isChecked, in: imageBounds.size)
    }
}

extension CheckboxAttachment {
    static func render(checked: Bool, in size: CGSize) -> PlatformImage {
        #if canImport(AppKit) && os(macOS)
        return NSImage(size: size, flipped: true) { rect in
            draw(checked: checked, in: rect)
            return true
        }
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(checked: checked, in: CGRect(origin: .zero, size: size))
        }
        #endif
    }

    static func draw(checked: Bool, in rect: CGRect) {
        let inset: CGFloat = 1
        let cornerRadius: CGFloat = max(2, rect.width * 0.18)
        let box = rect.insetBy(dx: inset, dy: inset)
        let path = PlatformBezierPath.roundedRect(rect: box, cornerRadius: cornerRadius)

        if checked {
            checkboxFillColor.setFill()
            path.fill()
        } else {
            #if canImport(AppKit) && os(macOS)
            NSColor.windowBackgroundColor.setFill()
            #else
            UIColor.systemBackground.setFill()
            #endif
            path.fill()
        }

        path.lineWidth = max(1, rect.width * 0.08)
        checkboxStrokeColor.setStroke()
        path.stroke()

        if checked {
            #if canImport(AppKit) && os(macOS)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            #else
            guard let context = UIGraphicsGetCurrentContext() else { return }
            #endif
            context.saveGState()
            context.setStrokeColor(checkboxCheckColor.cgColor)
            context.setLineWidth(max(1.5, rect.width * 0.13))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.52))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.72))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.32))
            context.strokePath()
            context.restoreGState()
        }
    }

    static var checkboxStrokeColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor
        #else
        return UIColor.tertiaryLabel
        #endif
    }

    static var checkboxFillColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.controlAccentColor
        #else
        return UIColor.tintColor
        #endif
    }

    static var checkboxCheckColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.white
        #else
        return UIColor.white
        #endif
    }
}
