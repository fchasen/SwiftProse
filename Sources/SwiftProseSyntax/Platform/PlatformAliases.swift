import Foundation

#if canImport(AppKit) && os(macOS)
import AppKit
public typealias PlatformView = NSView
public typealias PlatformTextView = NSTextView
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformFontDescriptor = NSFontDescriptor
public typealias PlatformImage = NSImage
public typealias PlatformTextStorageEditActions = NSTextStorageEditActions
#elseif canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
public typealias PlatformTextView = UITextView
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformFontDescriptor = UIFontDescriptor
public typealias PlatformImage = UIImage
public typealias PlatformTextStorageEditActions = NSTextStorage.EditActions
#endif

public struct FontTraits: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = FontTraits(rawValue: 1 << 0)
    public static let italic = FontTraits(rawValue: 1 << 1)
}

extension PlatformFont {
    public var fontTraits: FontTraits {
        var out: FontTraits = []
        let symbolic = fontDescriptor.symbolicTraits
        #if canImport(AppKit) && os(macOS)
        if symbolic.contains(.bold) { out.insert(.bold) }
        if symbolic.contains(.italic) { out.insert(.italic) }
        #else
        if symbolic.contains(.traitBold) { out.insert(.bold) }
        if symbolic.contains(.traitItalic) { out.insert(.italic) }
        #endif
        return out
    }

    public var isMonospace: Bool {
        #if canImport(AppKit) && os(macOS)
        return fontDescriptor.symbolicTraits.contains(.monoSpace)
        #else
        return fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        #endif
    }

    public func withFontTraits(_ traits: FontTraits, scale: CGFloat = 1.0) -> PlatformFont {
        let size = pointSize * scale
        #if canImport(AppKit) && os(macOS)
        var nsTraits: NSFontDescriptor.SymbolicTraits = []
        if traits.contains(.bold) { nsTraits.insert(.bold) }
        if traits.contains(.italic) { nsTraits.insert(.italic) }
        let descriptor = fontDescriptor.withSymbolicTraits(nsTraits)
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
        #else
        var uiTraits: UIFontDescriptor.SymbolicTraits = []
        if traits.contains(.bold) { uiTraits.insert(.traitBold) }
        if traits.contains(.italic) { uiTraits.insert(.traitItalic) }
        if let d = fontDescriptor.withSymbolicTraits(uiTraits) {
            return UIFont(descriptor: d, size: size)
        }
        return UIFont.systemFont(ofSize: size)
        #endif
    }

    public func togglingFontTrait(_ trait: FontTraits, enable: Bool) -> PlatformFont {
        var traits = fontTraits
        if enable { traits.insert(trait) } else { traits.remove(trait) }
        return withFontTraits(traits)
    }

    public var isSystemFont: Bool {
        let name = fontName
        return name.hasPrefix(".") || name == "AppleSystemUIFont"
    }

    public func withWeight(_ weight: Weight, size: CGFloat) -> PlatformFont {
        #if canImport(AppKit) && os(macOS)
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        if isSystemFont {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        #else
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        let candidate = UIFont(descriptor: descriptor, size: size)
        if isSystemFont {
            return candidate
        }
        if candidate.fontName != fontName || candidate.fontDescriptor != fontDescriptor {
            return candidate
        }
        #endif
        let scale = pointSize == 0 ? 1.0 : size / pointSize
        let bold = weight.rawValue >= Weight.semibold.rawValue
        return bold ? withFontTraits(.bold, scale: scale) : withFontTraits([], scale: scale)
    }
}

extension PlatformColor {
    package static var blockquoteDefaultBar: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.tertiaryLabelColor
        #else
        return UIColor.tertiaryLabel
        #endif
    }

    package static var horizontalRuleDefault: PlatformColor {
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

    package static var codeBlockDefaultTag: PlatformColor {
        #if canImport(AppKit) && os(macOS)
        return NSColor.secondaryLabelColor
        #else
        return UIColor.secondaryLabel
        #endif
    }
}
