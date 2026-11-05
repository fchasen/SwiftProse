import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct Restyler {
    var theme: ProseTheme
    var preservesCodeForeground = false

    static let quoteIndent: CGFloat = 16
    static let listIndent: CGFloat = 36
    static let codeInset: CGFloat = 8
    static let codeEdgeSpacing: CGFloat = 8
    static let headingSpacingAfter: CGFloat = 4

    func restyleAll(_ storage: NSMutableAttributedString) {
        restyle(storage, in: NSRange(location: 0, length: storage.length))
    }

    func restyle(_ storage: NSMutableAttributedString, in range: NSRange, excluding excluded: NSRange? = nil) {
        guard storage.length > 0 else { return }
        let scan = Normalizer.clamp(range, to: storage.length)
        let fonts = FontCache()
        var tableEnd = 0
        for paragraph in storage.markdownParagraphRanges(in: scan) where paragraph.length > 0 {
            guard paragraph.location >= tableEnd else { continue }
            if storage.markdownBlock(at: paragraph.location)?.isTableRow == true {
                let rows = storage.markdownTableRowRanges(at: paragraph.location)
                tableEnd = rows.last.map(NSMaxRange) ?? NSMaxRange(paragraph)
                if let excluded, rows.contains(where: { Normalizer.paragraph($0, intersects: excluded) }) { continue }
                restyleTable(rows, in: storage, fonts: fonts)
                continue
            }
            if let excluded, Normalizer.paragraph(paragraph, intersects: excluded) { continue }
            restyleParagraph(paragraph, in: storage, fonts: fonts)
        }
    }

    private func restyleTable(_ rows: [NSRange], in storage: NSMutableAttributedString, fonts: FontCache) {
        guard let first = rows.first, let firstBlock = storage.markdownBlock(at: first.location) else { return }
        let alignments = firstBlock.tableAlignments
        var cellWidths: [[CGFloat]] = []
        for row in rows {
            let block = storage.markdownBlock(at: row.location) ?? firstBlock
            restyleCharacters(row, block: block, in: storage, fonts: fonts)
            cellWidths.append(storage.markdownTableCellRanges(inRow: row).map { cell in
                cell.length == 0 ? 0 : ceil(storage.attributedSubstring(from: cell).size().width)
            })
        }
        let padding = TableMetrics.cellPadding
        let columnCount = max(1, alignments.count, cellWidths.map(\.count).max() ?? 0)
        var widths = [CGFloat](repeating: TableMetrics.minimumColumnWidth, count: columnCount)
        for row in cellWidths {
            for (column, width) in row.enumerated() {
                widths[column] = max(widths[column], width + padding.width * 2)
            }
        }
        let origin = Self.indent(for: firstBlock)
        var edges = [origin]
        for width in widths { edges.append(edges[edges.count - 1] + width) }
        func alignment(_ column: Int) -> TableColumnAlignment {
            column < alignments.count ? alignments[column] : .none
        }
        let tabStops: [NSTextTab] = (1..<max(1, columnCount)).map { column in
            let start = edges[column]
            switch alignment(column) {
            case .none, .left:
                return NSTextTab(textAlignment: .left, location: start + padding.width)
            case .center:
                return NSTextTab(textAlignment: .center, location: start + widths[column] / 2)
            case .right:
                return NSTextTab(textAlignment: .right, location: edges[column + 1] - padding.width)
            }
        }
        for (index, row) in rows.enumerated() {
            let block = storage.markdownBlock(at: row.location) ?? firstBlock
            let existing = storage.attribute(.paragraphStyle, at: row.location, effectiveRange: nil) as? NSParagraphStyle
            let base = paragraphStyle(for: block, textLists: existing?.textLists ?? [])
            let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            let firstCell = cellWidths[index].first ?? 0
            let leading: CGFloat
            switch alignment(0) {
            case .none, .left: leading = origin + padding.width
            case .center: leading = origin + max(padding.width, (widths[0] - firstCell) / 2)
            case .right: leading = origin + max(padding.width, widths[0] - padding.width - firstCell)
            }
            style.firstLineHeadIndent = leading
            style.headIndent = origin + padding.width
            style.tabStops = tabStops
            style.defaultTabInterval = padding.width
            if index == 0 { style.paragraphSpacingBefore += TableMetrics.edgeSpacing }
            if index == rows.count - 1 { style.paragraphSpacing += TableMetrics.edgeSpacing }
            let final = style.copy() as? NSParagraphStyle ?? style
            Self.set(.paragraphStyle, final, over: row, storage: storage)
            Self.set(
                .markdownTableGeometry,
                TableRowGeometry(columnEdges: edges, rowIndex: index, rowCount: rows.count),
                over: row,
                storage: storage
            )
        }
    }

    private static func set(_ key: NSAttributedString.Key, _ value: NSObject, over range: NSRange, storage: NSMutableAttributedString) {
        var effective = NSRange()
        let current = storage.attribute(key, at: range.location, longestEffectiveRange: &effective, in: range)
        if (current as? NSObject)?.isEqual(value) == true, NSEqualRanges(effective, range) { return }
        storage.addAttribute(key, value: value, range: range)
    }

    private func restyleParagraph(_ paragraph: NSRange, in storage: NSMutableAttributedString, fonts: FontCache) {
        let block = storage.markdownBlock(at: paragraph.location) ?? .paragraph
        let existing = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        var isFirstCodeLine = false
        var isLastCodeLine = false
        if let group = block.codeGroup {
            let previous = paragraph.location > 0 ? storage.markdownBlock(at: paragraph.location - 1) : nil
            let next = NSMaxRange(paragraph) < storage.length ? storage.markdownBlock(at: NSMaxRange(paragraph)) : nil
            isFirstCodeLine = previous?.codeGroup != group
            isLastCodeLine = next?.codeGroup != group
        }
        let style = paragraphStyle(
            for: block,
            textLists: existing?.textLists ?? [],
            isFirstCodeLine: isFirstCodeLine,
            isLastCodeLine: isLastCodeLine,
            isRightToLeft: !block.isCode && !block.isTableRow && Self.startsRightToLeft(storage.string as NSString, in: paragraph)
        )
        var styleRange = NSRange()
        let current = storage.attribute(.paragraphStyle, at: paragraph.location, longestEffectiveRange: &styleRange, in: paragraph)
        if !((current as? NSParagraphStyle)?.isEqual(style) == true && NSEqualRanges(styleRange, paragraph)) {
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
        if storage.attribute(.markdownTableGeometry, at: paragraph.location, effectiveRange: nil) != nil {
            storage.removeAttribute(.markdownTableGeometry, range: paragraph)
        }
        restyleCharacters(paragraph, block: block, in: storage, fonts: fonts)
    }

    private func restyleCharacters(
        _ paragraph: NSRange,
        block: MarkdownBlock,
        in storage: NSMutableAttributedString,
        fonts: FontCache
    ) {
        let preservesForeground = preservesCodeForeground && block.isCode
        storage.enumerateAttributes(in: paragraph) { attributes, run, _ in
            let intent = attributes.markdownInlineIntent
            let isLink = attributes[.link] != nil
            let wanted = characterAttributes(for: block, intent: intent, isLink: isLink, fonts: fonts)
            Self.set(.font, wanted.font, current: attributes[.font], in: run, storage: storage)
            if !preservesForeground || attributes[.foregroundColor] == nil {
                Self.set(.foregroundColor, wanted.color, current: attributes[.foregroundColor], in: run, storage: storage)
            }
            Self.set(.backgroundColor, wanted.background, current: attributes[.backgroundColor], in: run, storage: storage)
            Self.set(.strikethroughStyle, wanted.strikethrough, current: attributes[.strikethroughStyle], in: run, storage: storage)
        }
    }

    private static func set(
        _ key: NSAttributedString.Key,
        _ value: NSObject?,
        current: Any?,
        in range: NSRange,
        storage: NSMutableAttributedString
    ) {
        if let value {
            if (current as? NSObject)?.isEqual(value) != true {
                storage.addAttribute(key, value: value, range: range)
            }
        } else if current != nil {
            storage.removeAttribute(key, range: range)
        }
    }

    private struct CharacterAttributes {
        var font: PlatformFont
        var color: PlatformColor
        var background: PlatformColor?
        var strikethrough: NSNumber?
    }

    private func characterAttributes(
        for block: MarkdownBlock,
        intent: MarkdownInlineIntent,
        isLink: Bool,
        fonts: FontCache
    ) -> CharacterAttributes {
        let isCodeBlock = block.isCode
        let marks = isCodeBlock ? [] : intent.intersection(.markdownMarks)
        let key = FontKey(leaf: FontKey.leafKey(block), quote: block.isInQuote, marks: marks.rawValue)
        let font = fonts.font(for: key) { self.font(for: block, intent: marks) }
        return CharacterAttributes(
            font: font,
            color: color(for: block, isLink: isLink && !isCodeBlock),
            background: marks.contains(.code) ? theme.codeBlock.fillColor : nil,
            strikethrough: marks.contains(.strikethrough) ? NSNumber(value: NSUnderlineStyle.single.rawValue) : nil
        )
    }

    func font(for block: MarkdownBlock, intent: MarkdownInlineIntent) -> PlatformFont {
        let base: PlatformFont
        switch block.leaf {
        case .code:
            return theme.monospaceFont
        case .heading(let level):
            base = theme.headingFont(level: level)
        case .paragraph, .thematicBreak, .tableRow, .html:
            base = theme.bodyFont
        }
        var traits = base.fontTraits
        if block.isTableHeader { traits.insert(.bold) }
        if block.isInQuote { traits.formUnion(theme.blockquote.textTraits) }
        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }
        if intent.contains(.code) {
            let mono = Self.resized(theme.monospaceFont, to: base.pointSize)
            return traits.isEmpty ? mono : mono.withFontTraits(traits)
        }
        return traits == base.fontTraits ? base : base.withFontTraits(traits)
    }

    func color(for block: MarkdownBlock, isLink: Bool) -> PlatformColor {
        if isLink { return theme.linkColor }
        if block.isCode { return theme.codeBlock.textColor ?? theme.foregroundColor }
        if block.isInQuote { return theme.blockquote.textColor ?? theme.foregroundColor }
        return theme.foregroundColor
    }

    static func startsRightToLeft(_ string: NSString, in range: NSRange) -> Bool {
        for scalar in string.substring(with: range).unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                if scalar.properties.isAlphabetic { return false }
            }
        }
        return false
    }

    static func indent(for block: MarkdownBlock) -> CGFloat {
        var indent: CGFloat = 0
        for container in block.containers {
            switch container {
            case .quote: indent += quoteIndent
            case .listItem: indent += listIndent
            }
        }
        if block.isCode { indent += codeInset }
        return indent
    }

    func paragraphStyle(
        for block: MarkdownBlock,
        textLists: [NSTextList],
        isFirstCodeLine: Bool = false,
        isLastCodeLine: Bool = false,
        isRightToLeft: Bool = false
    ) -> NSParagraphStyle {
        let style = (theme.defaultParagraphStyle().mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        if isRightToLeft { style.baseWritingDirection = .rightToLeft }
        style.textLists = textLists
        let indent = Self.indent(for: block)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        switch block.leaf {
        case .heading(let level):
            style.paragraphSpacingBefore = CGFloat(max(0, 7 - level)) * 2
            style.paragraphSpacing = Self.headingSpacingAfter
        case .code:
            style.paragraphSpacingBefore = isFirstCodeLine ? Self.codeEdgeSpacing : 0
            style.paragraphSpacing = isLastCodeLine ? Self.codeEdgeSpacing : 0
        case .tableRow:
            style.paragraphSpacingBefore = TableMetrics.cellPadding.height
            style.paragraphSpacing = TableMetrics.cellPadding.height
            style.baseWritingDirection = .leftToRight
            style.alignment = .left
            style.firstLineHeadIndent = indent + TableMetrics.cellPadding.width
            style.headIndent = indent + TableMetrics.cellPadding.width
        case .paragraph, .thematicBreak, .html:
            break
        }
        return style.copy() as? NSParagraphStyle ?? style
    }

    func typingAttributes(
        for block: MarkdownBlock,
        intent: MarkdownInlineIntent,
        paragraphStyle: NSParagraphStyle?
    ) -> [NSAttributedString.Key: Any] {
        let wanted = characterAttributes(for: block, intent: intent, isLink: false, fonts: FontCache())
        var attributes: [NSAttributedString.Key: Any] = [
            .font: wanted.font,
            .foregroundColor: wanted.color,
            .paragraphStyle: paragraphStyle ?? self.paragraphStyle(for: block, textLists: [])
        ]
        if let background = wanted.background { attributes[.backgroundColor] = background }
        if let strikethrough = wanted.strikethrough { attributes[.strikethroughStyle] = strikethrough }
        attributes.markdownBlock = block
        attributes.markdownInlineIntent = block.isCode ? intent.intersection(.softBreak) : intent
        return attributes
    }

    private static func resized(_ font: PlatformFont, to size: CGFloat) -> PlatformFont {
        guard font.pointSize != size else { return font }
        #if canImport(AppKit) && os(macOS)
        return NSFont(descriptor: font.fontDescriptor, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        return UIFont(descriptor: font.fontDescriptor, size: size)
        #endif
    }
}

private struct FontKey: Hashable {
    let leaf: Int
    let quote: Bool
    let marks: UInt

    static func leafKey(_ block: MarkdownBlock) -> Int {
        switch block.leaf {
        case .code: return -1
        case .heading(let level): return level
        case .tableRow(_, _, let isHeader): return isHeader ? -2 : 0
        case .paragraph, .thematicBreak, .html: return 0
        }
    }
}

private final class FontCache {
    private var fonts: [FontKey: PlatformFont] = [:]

    func font(for key: FontKey, make: () -> PlatformFont) -> PlatformFont {
        if let cached = fonts[key] { return cached }
        let font = make()
        fonts[key] = font
        return font
    }
}
