import Foundation

#if canImport(AppKit) && os(macOS)
import AppKit
public typealias PlatformView = NSView
public typealias PlatformTextView = NSTextView
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformFontDescriptor = NSFontDescriptor
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
public typealias PlatformTextView = UITextView
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformFontDescriptor = UIFontDescriptor
public typealias PlatformImage = UIImage
#endif

public struct FontTraits: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = FontTraits(rawValue: 1 << 0)
    public static let italic = FontTraits(rawValue: 1 << 1)
}

extension PlatformFont {
    /// Read the bold/italic traits encoded on the font's descriptor. Used by
    /// the serializer to decide whether to wrap a run in `**`/`*`.
    public var proseTraits: FontTraits {
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

    /// Return a font derived from this one with `traits` applied and
    /// optionally rescaled by `scale`. Used by the compiler when emitting
    /// styled inline runs (bold, italic) and by the controller's stored-mark
    /// machinery when synthesizing typing attributes.
    public func withProseTraits(_ traits: FontTraits, scale: CGFloat = 1.0) -> PlatformFont {
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

    /// Toggle a single trait on or off, preserving the others. Used by the
    /// inline-mark toggle commands when toggling bold/italic over a
    /// selection of arbitrary existing styles.
    public func togglingProseTrait(_ trait: FontTraits, enable: Bool) -> PlatformFont {
        var traits = proseTraits
        if enable { traits.insert(trait) } else { traits.remove(trait) }
        return withProseTraits(traits)
    }
}
