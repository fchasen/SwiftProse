import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public typealias MarkdownInlineIntent = InlinePresentationIntent

extension NSAttributedString.Key {
    public static let markdownBlock = NSAttributedString.Key("swiftprose.block")
    public static let markdownLiteral = NSAttributedString.Key("swiftprose.literal")
    public static let markdownInlineIntent = NSAttributedString.Key("swiftprose.inline")
    public static let markdownTableSeparator = NSAttributedString.Key("swiftprose.tableSeparator")
}

extension MarkdownInlineIntent {
    public static let markdownMarks: MarkdownInlineIntent = [
        .stronglyEmphasized, .emphasized, .code, .strikethrough
    ]

    public var attributeValue: NSNumber {
        NSNumber(value: rawValue)
    }

    public init?(attributeValue: Any?) {
        switch attributeValue {
        case let number as NSNumber:
            self.init(rawValue: number.uintValue)
        case let intent as MarkdownInlineIntent:
            self = intent
        case let raw as UInt:
            self.init(rawValue: raw)
        case let raw as Int where raw >= 0:
            self.init(rawValue: UInt(raw))
        default:
            return nil
        }
    }
}

public enum MarkdownBreak {
    public static let character: Character = "\u{2028}"
    public static let string = "\u{2028}"
    public static let utf16: unichar = 0x2028
}

public enum MarkdownTableSeparator {
    public static let character: Character = "\t"
    public static let string = "\t"
    public static let utf16: unichar = 0x09
}

public enum MarkdownParagraph {
    public static let separator: unichar = 0x0A
    public static let objectReplacement: unichar = 0xFFFC
}

extension NSAttributedString {
    public func markdownBlock(at index: Int) -> MarkdownBlock? {
        guard index >= 0, index < length else { return nil }
        return attribute(.markdownBlock, at: index, effectiveRange: nil) as? MarkdownBlock
    }

    public func markdownInlineIntent(at index: Int) -> MarkdownInlineIntent {
        guard index >= 0, index < length else { return [] }
        return MarkdownInlineIntent(
            attributeValue: attribute(.markdownInlineIntent, at: index, effectiveRange: nil)
        ) ?? []
    }

    public func markdownLiteral(at index: Int) -> String? {
        guard index >= 0, index < length else { return nil }
        return attribute(.markdownLiteral, at: index, effectiveRange: nil) as? String
    }

    public func markdownLink(at index: Int) -> String? {
        guard index >= 0, index < length else { return nil }
        switch attribute(.link, at: index, effectiveRange: nil) {
        case let url as URL: return url.absoluteString
        case let string as String: return string
        default: return nil
        }
    }

    public func isMarkdownCode(at index: Int) -> Bool {
        if markdownBlock(at: index)?.isCode == true { return true }
        return markdownInlineIntent(at: index).contains(.code)
    }

    public func isMarkdownBreak(at index: Int) -> Bool {
        guard index >= 0, index < length else { return false }
        return (string as NSString).character(at: index) == MarkdownBreak.utf16
    }

    public func isMarkdownSoftBreak(at index: Int) -> Bool {
        isMarkdownBreak(at: index) && markdownInlineIntent(at: index).contains(.softBreak)
    }

    public func isMarkdownHardBreak(at index: Int) -> Bool {
        isMarkdownBreak(at: index) && !markdownInlineIntent(at: index).contains(.softBreak)
    }

    public func isMarkdownTableSeparator(at index: Int) -> Bool {
        guard index >= 0, index < length else { return false }
        return (string as NSString).character(at: index) == MarkdownTableSeparator.utf16
            && markdownBlock(at: index)?.isTableRow == true
    }

    public func proseSourceAttachment(at index: Int) -> (NSTextAttachment & ProseSourceAttachment)? {
        guard index >= 0, index < length else { return nil }
        return attribute(.attachment, at: index, effectiveRange: nil) as? (NSTextAttachment & ProseSourceAttachment)
    }

    public func markdownParagraphRange(at index: Int) -> NSRange {
        let ns = string as NSString
        let clamped = max(0, min(index, ns.length))
        return ns.paragraphRange(for: NSRange(location: clamped, length: 0))
    }

    public func markdownParagraphRanges(in range: NSRange? = nil) -> [NSRange] {
        let ns = string as NSString
        let total = ns.length
        let scan = range ?? NSRange(location: 0, length: total)
        let start = max(0, min(scan.location, total))
        let end = max(start, min(NSMaxRange(scan), total))
        let endsWithSeparator = total > 0 && ns.character(at: total - 1) == MarkdownParagraph.separator
        var ranges: [NSRange] = []
        var location = ns.paragraphRange(for: NSRange(location: start, length: 0)).location
        while true {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            let reachesTrailingEmpty = next == total && end == total && endsWithSeparator
            guard paragraph.length > 0, next < end || reachesTrailingEmpty else { break }
            location = next
        }
        return ranges
    }
}

extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    public var markdownBlock: MarkdownBlock? {
        get { self[.markdownBlock] as? MarkdownBlock }
        set { self[.markdownBlock] = newValue }
    }

    public var markdownInlineIntent: MarkdownInlineIntent {
        get { MarkdownInlineIntent(attributeValue: self[.markdownInlineIntent]) ?? [] }
        set { self[.markdownInlineIntent] = newValue.isEmpty ? nil : newValue.attributeValue }
    }
}

extension NSTextList {
    package var hasOrderedMarker: Bool {
        switch markerFormat {
        case .disc, .circle, .square, .hyphen, .box, .check, .diamond:
            return false
        case .decimal, .octal, .lowercaseHexadecimal, .uppercaseHexadecimal, .lowercaseAlpha, .uppercaseAlpha,
             .lowercaseLatin, .uppercaseLatin, .lowercaseRoman, .uppercaseRoman:
            return true
        default:
            return isOrdered
        }
    }
}
