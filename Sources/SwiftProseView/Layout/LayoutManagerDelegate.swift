import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class LayoutManagerDelegate: NSObject, NSTextLayoutManagerDelegate {
    public weak var controller: EditorController?

    public init(controller: EditorController? = nil) {
        self.controller = controller
        super.init()
    }

    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let plain = NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        guard let controller,
              let elementRange = textElement.elementRange else {
            return plain
        }
        let contentStorage = controller.textContentStorage
        let storage = controller.textStorage
        let elementStart = contentStorage.offset(from: contentStorage.documentRange.location, to: elementRange.location)
        let total = storage.length
        guard total > 0, elementStart >= 0, elementStart < total,
              let block = storage.markdownBlock(at: elementStart) else {
            return plain
        }
        let decorations = FragmentDecorations.make(paragraphAt: elementStart, controller: controller)
        let fragment: MarkdownLayoutFragment
        if let group = block.codeGroup {
            let paragraph = storage.markdownParagraphRange(at: elementStart)
            let previous = paragraph.location > 0 ? storage.markdownBlock(at: paragraph.location - 1) : nil
            let next = NSMaxRange(paragraph) < total ? storage.markdownBlock(at: NSMaxRange(paragraph)) : nil
            let code = FencedCodeBlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
            code.language = block.codeLanguage
            code.isFirstLine = previous?.codeGroup != group
            code.isLastLine = next?.codeGroup != group
            code.containerWidth = controller.textContainer.size.width
            code.fillColor = controller.theme.codeBlock.fillColor
            code.languageTagColor = controller.theme.codeBlock.languageTagColor
            fragment = code
        } else if block.isTableRow {
            let row = TableRowLayoutFragment(textElement: textElement, range: textElement.elementRange)
            row.palette = controller.theme.tablePalette
            row.isHeader = block.isTableHeader
            row.fixedGeometry = storage.attribute(.markdownTableGeometry, at: elementStart, effectiveRange: nil) as? TableRowGeometry
            row.fixedLeadingIndent = (storage.attribute(.paragraphStyle, at: elementStart, effectiveRange: nil) as? NSParagraphStyle)?
                .firstLineHeadIndent ?? 0
            fragment = row
        } else if decorations.isDecorated
                    || storage.containsImagelessAttachment(in: storage.markdownParagraphRange(at: elementStart)) {
            fragment = MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange)
        } else {
            return plain
        }
        fragment.controller = controller
        fragment.fixedDecorations = decorations
        return fragment
    }
}

extension NSAttributedString {
    func containsImagelessAttachment(in range: NSRange) -> Bool {
        var found = false
        enumerateAttribute(.attachment, in: range) { value, _, stop in
            if let attachment = value as? NSTextAttachment, attachment.image == nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}

struct FragmentDecorations {
    var marker: ListMarker?
    var quoteBars: [QuoteBar] = []
    var barColor: PlatformColor = .blockquoteDefaultBar
    var leadingIndent: CGFloat = 0
    var markerIndent: CGFloat = 0
    var isRightToLeft = false

    var isDecorated: Bool { marker != nil || !quoteBars.isEmpty }

    static func make(paragraphAt location: Int, controller: EditorController) -> FragmentDecorations {
        let storage = controller.textStorage
        let total = storage.length
        guard location >= 0, location < total else { return FragmentDecorations() }
        let paragraph = storage.markdownParagraphRange(at: location)
        guard let block = storage.markdownBlock(at: paragraph.location) else { return FragmentDecorations() }
        let previous = paragraph.location > 0 ? storage.markdownBlock(at: paragraph.location - 1) : nil
        let next = NSMaxRange(paragraph) < total ? storage.markdownBlock(at: NSMaxRange(paragraph)) : nil
        let font = block.headingLevel.map { controller.theme.headingFont(level: $0) } ?? controller.theme.bodyFont
        let color = controller.restyler.color(for: block.with(leaf: .paragraph), isLink: false)
        return FragmentDecorations(
            marker: ListNumbering.markerKind(at: paragraph.location, in: storage, ordinal: {
                controller.decorationCache.ordinal(at: $0, in: storage)
            }).map {
                ListMarker(kind: $0, font: font, color: color)
            },
            quoteBars: quoteBars(for: block, previous: previous, next: next),
            barColor: controller.theme.blockquote.barColor,
            leadingIndent: Restyler.indent(for: block),
            markerIndent: ListNumbering.listContentIndent(for: block),
            isRightToLeft: storage.isRightToLeftParagraph(at: paragraph.location)
        )
    }

    static func quoteBars(for block: MarkdownBlock, previous: MarkdownBlock?, next: MarkdownBlock?) -> [QuoteBar] {
        let tokens = block.quoteTokens
        guard !tokens.isEmpty else { return [] }
        let offsets = ListNumbering.leadingOffsets(ofQuotesIn: block)
        let previousTokens = previous?.quoteTokens ?? []
        let nextTokens = next?.quoteTokens ?? []
        return tokens.indices.map { index in
            QuoteBar(
                offset: offsets[index],
                isFirstInRun: !(index < previousTokens.count && previousTokens[index] == tokens[index]),
                isLastInRun: !(index < nextTokens.count && nextTokens[index] == tokens[index])
            )
        }
    }
}
