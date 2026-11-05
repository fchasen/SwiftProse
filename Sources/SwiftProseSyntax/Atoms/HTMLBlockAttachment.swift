import Foundation
import CoreGraphics
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class HTMLBlockAttachment: NSTextAttachment, ProseSourceAttachment {
    public var markdownSource: String { didSet { rendered = nil } }
    public var contentKind: String = AtomKind.htmlBlock
    public var font: PlatformFont { didSet { rendered = nil } }
    public var monospaceFont: PlatformFont { didSet { rendered = nil } }
    public var textColor: PlatformColor { didSet { rendered = nil } }
    public var fillColor: PlatformColor

    static let padding = CGSize(width: 8, height: 6)

    private var rendered: NSAttributedString?

    public init(markdownSource: String) {
        self.markdownSource = markdownSource
        self.font = Self.defaultFont
        self.monospaceFont = Self.defaultMonospaceFont
        self.textColor = Self.defaultTextColor
        self.fillColor = Self.defaultFillColor
        super.init(data: nil, ofType: nil)
    }

    public required init?(coder: NSCoder) {
        self.markdownSource = ""
        self.font = Self.defaultFont
        self.monospaceFont = Self.defaultMonospaceFont
        self.textColor = Self.defaultTextColor
        self.fillColor = Self.defaultFillColor
        super.init(coder: coder)
    }

    static var defaultFont: PlatformFont {
        PlatformFont.systemFont(ofSize: PlatformFont.systemFontSize)
    }

    static var defaultMonospaceFont: PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .regular)
    }

    static var defaultTextColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.labelColor
        #else
        return UIColor.label
        #endif
    }

    static var defaultFillColor: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.08)
        #else
        return UIColor.tertiaryLabel.withAlphaComponent(0.08)
        #endif
    }

    public var renderedContent: NSAttributedString {
        if let rendered { return rendered }
        guard Thread.isMainThread, let imported = importHTML() else {
            return sourceRendering()
        }
        rendered = imported
        return imported
    }

    func sourceRendering() -> NSAttributedString {
        NSAttributedString(string: markdownSource, attributes: [
            .font: monospaceFont,
            .foregroundColor: textColor
        ])
    }

    private func importHTML() -> NSAttributedString? {
        guard let data = markdownSource.data(using: .utf8),
              let imported = try? NSMutableAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              )
        else { return nil }
        while imported.length > 0, imported.string.last?.isNewline == true {
            imported.deleteCharacters(in: NSRange(location: imported.length - 1, length: 1))
        }
        guard imported.length > 0 else { return nil }
        let full = NSRange(location: 0, length: imported.length)
        imported.enumerateAttribute(.font, in: full) { value, range, _ in
            let original = value as? PlatformFont
            let base = original?.isMonospace == true ? monospaceFont : font
            let traits = original?.fontTraits ?? []
            imported.addAttribute(.font, value: traits.isEmpty ? base : base.withFontTraits(traits), range: range)
        }
        imported.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value == nil else { return }
            imported.addAttribute(.foregroundColor, value: textColor, range: range)
        }
        imported.removeAttribute(.link, range: full)
        imported.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            #if canImport(AppKit) && os(macOS)
            guard !style.textBlocks.isEmpty else { return }
            let flattened = style.mutableCopy() as! NSMutableParagraphStyle
            flattened.textBlocks = []
            imported.addAttribute(.paragraphStyle, value: flattened, range: range)
            #else
            _ = style
            #endif
        }
        return imported
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
        let width = Self.availableWidth(lineFrag: lineFrag, textContainer: textContainer)
        let content = renderedContent
        let textWidth = max(1, width - Self.padding.width * 2)
        let height = content.boundingRect(
            with: CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        ).height
        return CGRect(x: 0, y: 0, width: width, height: ceil(height) + Self.padding.height * 2)
    }

    public override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> PlatformImage? {
        let content = renderedContent
        let fill = fillColor
        return Self.renderImage(size: imageBounds.size) { rect in
            fill.setFill()
            #if canImport(AppKit) && os(macOS)
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            #else
            UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
            #endif
            content.draw(
                with: rect.insetBy(dx: Self.padding.width, dy: Self.padding.height),
                options: [.usesLineFragmentOrigin],
                context: nil
            )
        }
    }

    static func availableWidth(lineFrag: CGRect, textContainer: NSTextContainer?) -> CGFloat {
        if lineFrag.width > 0, lineFrag.width < .greatestFiniteMagnitude / 2 { return lineFrag.width }
        if let width = textContainer?.size.width, width > 0, width < .greatestFiniteMagnitude / 2 { return width }
        return 480
    }

    static func renderImage(size: CGSize, _ draw: @escaping (CGRect) -> Void) -> PlatformImage {
        #if canImport(AppKit) && os(macOS)
        return NSImage(size: size, flipped: true) { rect in
            draw(rect)
            return true
        }
        #else
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(CGRect(origin: .zero, size: size))
        }
        #endif
    }
}
