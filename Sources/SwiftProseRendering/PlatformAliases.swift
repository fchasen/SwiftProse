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

    /// True when this font is one of the system fonts (whose PostScript
    /// names start with `.` or use the `AppleSystemUIFont` alias). The
    /// theme's heading-font resolver uses this to decide between
    /// `systemFont(ofSize:weight:)` (which honors the exact weight slot)
    /// and the descriptor-based weight lookup used for named families.
    public var isSystemFont: Bool {
        let name = fontName
        return name.hasPrefix(".") || name == "AppleSystemUIFont"
    }

    /// Return a font in this font's family at `size` with the requested
    /// weight. System fonts use `systemFont(ofSize:weight:)` so the exact
    /// weight slot is honored. Named families are looked up via the font
    /// descriptor's weight trait — if no matching face exists, falls back
    /// to the bold trait (for `>= .semibold`) or a plain rescale.
    public func withWeight(_ weight: Weight, size: CGFloat) -> PlatformFont {
        if isSystemFont {
            return PlatformFont.systemFont(ofSize: size, weight: weight)
        }
        #if canImport(AppKit) && os(macOS)
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        if let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        #else
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
        ])
        let candidate = UIFont(descriptor: descriptor, size: size)
        // Only use the candidate if the family actually returned a face
        // distinct from the original at the requested weight.
        if candidate.fontName != fontName || candidate.fontDescriptor != fontDescriptor {
            return candidate
        }
        #endif
        let scale = pointSize == 0 ? 1.0 : size / pointSize
        let bold = weight.rawValue >= Weight.semibold.rawValue
        return bold ? withProseTraits(.bold, scale: scale) : withProseTraits([], scale: scale)
    }
}
