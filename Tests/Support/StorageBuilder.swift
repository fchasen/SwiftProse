import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftProseSyntax
import SwiftProseView

package struct StorageBuilder {
    package private(set) var result = NSMutableAttributedString()

    package init() {}

    @discardableResult
    package mutating func paragraph(
        _ text: String,
        _ block: MarkdownBlock = .paragraph,
        lists: [NSTextList] = [],
        separator: Bool = true
    ) -> NSRange {
        let start = result.length
        let piece = NSMutableAttributedString(string: separator ? text + "\n" : text)
        let full = NSRange(location: 0, length: piece.length)
        piece.addAttribute(.markdownBlock, value: block, range: full)
        if !lists.isEmpty {
            let style = NSMutableParagraphStyle()
            style.textLists = lists
            piece.addAttribute(.paragraphStyle, value: style.copy(), range: full)
        }
        result.append(piece)
        return NSRange(location: start, length: piece.length)
    }

    package static func build(_ body: (inout StorageBuilder) -> Void) -> NSMutableAttributedString {
        var builder = StorageBuilder()
        body(&builder)
        return builder.result
    }
}

extension NSMutableAttributedString {
    package func addIntent(_ intent: MarkdownInlineIntent, _ range: NSRange) {
        addAttribute(.markdownInlineIntent, value: intent.attributeValue, range: range)
    }

    package func blocks() -> [MarkdownBlock?] {
        markdownParagraphRanges().filter { $0.length > 0 }.map { markdownBlock(at: $0.location) }
    }

    package func isBlockUniform(in paragraph: NSRange) -> Bool {
        var effective = NSRange()
        _ = attribute(.markdownBlock, at: paragraph.location, longestEffectiveRange: &effective, in: paragraph)
        return NSEqualRanges(effective, paragraph)
    }

    package func paragraphStyle(at index: Int) -> NSParagraphStyle? {
        attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }
}

package enum Marks {
    package static var keyIsCustom: Bool {
        NSAttributedString.Key.markdownInlineIntent != .inlinePresentationIntent
    }
}
