import Foundation
import SwiftProseSyntax
import SwiftProseView
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

package struct LoadedParagraph {
    package let range: NSRange
    package let text: String
    package let block: MarkdownBlock?
    package let lists: [NSTextList]

    package var leaf: MarkdownBlock.Leaf? { block?.leaf }
    package var containers: [MarkdownBlock.Container] { block?.containers ?? [] }
}

package enum LoaderFixture {
    package static func paragraphs(_ storage: NSAttributedString) -> [LoadedParagraph] {
        let ns = storage.string as NSString
        return storage.markdownParagraphRanges().compactMap { range in
            guard range.length > 0 else { return nil }
            var content = range
            if ns.character(at: NSMaxRange(range) - 1) == MarkdownParagraph.separator {
                content.length -= 1
            }
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            return LoadedParagraph(
                range: content,
                text: ns.substring(with: content),
                block: storage.markdownBlock(at: range.location),
                lists: style?.textLists ?? []
            )
        }
    }

    package static func literals(_ storage: NSAttributedString) -> [String] {
        var out: [String] = []
        storage.enumerateAttribute(
            .markdownLiteral,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let source = value as? String else { return }
            out.append((storage.string as NSString).substring(with: range) + "=" + source)
        }
        return out
    }

    package static func intentRuns(_ storage: NSAttributedString, in range: NSRange? = nil) -> [(String, MarkdownInlineIntent)] {
        var out: [(String, MarkdownInlineIntent)] = []
        let ns = storage.string as NSString
        let scan = range ?? NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.markdownInlineIntent, in: scan) { value, range, _ in
            out.append((ns.substring(with: range), MarkdownInlineIntent(attributeValue: value) ?? []))
        }
        return out
    }

    package static func attachments(_ storage: NSAttributedString) -> [any ProseSourceAttachment] {
        var out: [any ProseSourceAttachment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let attachment = value as? (NSTextAttachment & ProseSourceAttachment) {
                out.append(attachment)
            }
        }
        return out
    }

    package static func blockIsUniform(_ storage: NSAttributedString) -> Bool {
        for paragraph in storage.markdownParagraphRanges() where paragraph.length > 0 {
            var effective = NSRange()
            guard storage.attribute(
                .markdownBlock,
                at: paragraph.location,
                longestEffectiveRange: &effective,
                in: paragraph
            ) is MarkdownBlock,
                  NSIntersectionRange(effective, paragraph) == paragraph
            else { return false }
        }
        return true
    }
}
