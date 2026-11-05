import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct PasteSanitizer {
    var inferHeadings = true

    static func normalizeLineEndings(_ string: String) -> String {
        guard string.contains(where: { lineEndingReplacements[$0] != nil || $0 == "\r\n" }) else { return string }
        var out = String()
        out.reserveCapacity(string.utf8.count)
        for character in string {
            if character == "\r\n" {
                out.append("\n")
            } else if let replacement = lineEndingReplacements[character] {
                out.append(replacement)
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static let lineEndingReplacements: [Character: Character] = [
        "\r": "\n",
        "\u{2029}": "\n",
        "\u{0085}": "\n",
        "\u{000C}": "\n",
        "\u{000B}": MarkdownBreak.character
    ]

    func sanitize(_ input: NSAttributedString) -> NSMutableAttributedString {
        let working = NSMutableAttributedString(attributedString: input)
        Self.normalizeLineEndings(in: working)
        Self.removeForeignAttachments(in: working)

        let paragraphs = working.markdownParagraphRanges().filter { $0.length > 0 }
        var analyses: [ParagraphAnalysis] = []
        analyses.reserveCapacity(paragraphs.count)
        var removed = 0
        for paragraph in paragraphs {
            let shifted = NSRange(location: paragraph.location - removed, length: paragraph.length)
            let analysis = Self.stripListMarker(in: shifted, storage: working)
            removed += shifted.length - analysis.range.length
            analyses.append(analysis)
        }

        let bodySize = Self.dominantFontSize(in: working)
        let output = NSMutableAttributedString(string: working.string)
        var looseList: NSTextList?
        var openCodeGroup: GroupToken?

        var openCodeLanguage: String?

        for (index, analysis) in analyses.enumerated() {
            let paragraph = analysis.range
            let content = Self.contentRange(of: paragraph, in: working)
            var lists = analysis.textLists
            if lists.isEmpty, analysis.hadBulletMarker {
                let list = looseList ?? NSTextList(markerFormat: .disc, options: 0)
                looseList = list
                lists = [list]
            } else {
                looseList = nil
            }

            let leaf: MarkdownBlock.Leaf
            if let group = openCodeGroup, Self.isBlank(content, in: working),
               Self.nextNonBlankIsCode(after: index, in: analyses, storage: working) {
                leaf = .code(language: openCodeLanguage, group: group)
            } else {
                leaf = paragraphLeaf(content: content, storage: working, bodySize: bodySize, openCodeGroup: &openCodeGroup)
                if case .code(let language, _) = leaf { openCodeLanguage = language }
            }
            let block = MarkdownBlock(leaf: leaf, containers: Array(repeating: .listItem, count: lists.count))
            output.addAttribute(.markdownBlock, value: block, range: paragraph)
            if !lists.isEmpty {
                let style = NSMutableParagraphStyle()
                style.textLists = lists
                output.addAttribute(.paragraphStyle, value: style.copy(), range: paragraph)
            }
            copyInlineAttributes(from: working, to: output, content: content, block: block)
        }
        return output
    }

    static func captureForeignAttributes(in storage: NSMutableAttributedString, range: NSRange) {
        let scan = Normalizer.clamp(range, to: storage.length)
        guard scan.length > 0 else { return }
        if NSAttributedString.Key.markdownInlineIntent != .inlinePresentationIntent {
            var captured: [(NSRange, MarkdownInlineIntent)] = []
            storage.enumerateAttribute(.inlinePresentationIntent, in: scan) { value, run, _ in
                guard let foreign = MarkdownInlineIntent(attributeValue: value) else { return }
                captured.append((run, foreign))
            }
            for (run, foreign) in captured {
                storage.enumerateAttribute(.markdownInlineIntent, in: run) { value, subrange, _ in
                    let existing = MarkdownInlineIntent(attributeValue: value) ?? []
                    let merged = existing.union(foreign.intersection(.markdownMarks))
                    if merged.isEmpty {
                        storage.removeAttribute(.markdownInlineIntent, range: subrange)
                    } else {
                        storage.addAttribute(.markdownInlineIntent, value: merged.attributeValue, range: subrange)
                    }
                }
                storage.removeAttribute(.inlinePresentationIntent, range: run)
            }
        }
        #if canImport(AppKit) && os(macOS)
        var blocked: [(NSRange, NSParagraphStyle)] = []
        storage.enumerateAttribute(.paragraphStyle, in: scan) { value, run, _ in
            guard let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty else { return }
            let stripped = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            stripped.textBlocks = []
            blocked.append((run, stripped.copy() as? NSParagraphStyle ?? stripped))
        }
        for (run, style) in blocked {
            storage.addAttribute(.paragraphStyle, value: style, range: run)
        }
        #endif
    }

    private struct ParagraphAnalysis {
        var range: NSRange
        var textLists: [NSTextList]
        var hadBulletMarker: Bool
    }

    private static let bulletMarkers: Set<Character> = ["•", "◦", "▪", "▫", "‣", "⁃", "-", "*", "+", "–", "○", "■", "□", "●"]

    private static func stripListMarker(in paragraph: NSRange, storage: NSMutableAttributedString) -> ParagraphAnalysis {
        let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        let lists = style?.textLists ?? []
        let ns = storage.string as NSString
        guard paragraph.length >= 2, ns.character(at: paragraph.location) == 0x09 else {
            return ParagraphAnalysis(range: paragraph, textLists: lists, hadBulletMarker: false)
        }
        let limit = min(NSMaxRange(paragraph), paragraph.location + 16)
        var closing: Int?
        for index in (paragraph.location + 1)..<limit {
            let unit = ns.character(at: index)
            if unit == 0x09 { closing = index; break }
            if unit == MarkdownParagraph.separator { break }
        }
        guard let closing else {
            return ParagraphAnalysis(range: paragraph, textLists: lists, hadBulletMarker: false)
        }
        let marker = ns.substring(with: NSRange(location: paragraph.location + 1, length: closing - paragraph.location - 1))
        let isBullet = marker.count == 1 && marker.first.map { bulletMarkers.contains($0) } == true
        guard !lists.isEmpty || isBullet else {
            return ParagraphAnalysis(range: paragraph, textLists: lists, hadBulletMarker: false)
        }
        let markerLength = closing - paragraph.location + 1
        storage.deleteCharacters(in: NSRange(location: paragraph.location, length: markerLength))
        return ParagraphAnalysis(
            range: NSRange(location: paragraph.location, length: paragraph.length - markerLength),
            textLists: lists,
            hadBulletMarker: isBullet
        )
    }

    private static func normalizeLineEndings(in storage: NSMutableAttributedString) {
        let ns = storage.string as NSString
        var index = ns.length - 1
        while index >= 0 {
            let unit = ns.character(at: index)
            switch unit {
            case 0x0A where index > 0 && ns.character(at: index - 1) == 0x0D:
                storage.deleteCharacters(in: NSRange(location: index - 1, length: 1))
                index -= 1
            case 0x0D, 0x2029, 0x0085, 0x000C:
                storage.replaceCharacters(in: NSRange(location: index, length: 1), with: "\n")
            case 0x000B:
                storage.replaceCharacters(in: NSRange(location: index, length: 1), with: MarkdownBreak.string)
            default:
                break
            }
            index -= 1
        }
    }

    private static func removeForeignAttachments(in storage: NSMutableAttributedString) {
        let ns = storage.string as NSString
        var index = ns.length - 1
        while index >= 0 {
            if ns.character(at: index) == MarkdownParagraph.objectReplacement,
               !(storage.attribute(.attachment, at: index, effectiveRange: nil) is ProseSourceAttachment) {
                storage.deleteCharacters(in: NSRange(location: index, length: 1))
            }
            index -= 1
        }
    }

    private static func contentRange(of paragraph: NSRange, in storage: NSAttributedString) -> NSRange {
        let ns = storage.string as NSString
        guard paragraph.length > 0, ns.character(at: NSMaxRange(paragraph) - 1) == MarkdownParagraph.separator else {
            return paragraph
        }
        return NSRange(location: paragraph.location, length: paragraph.length - 1)
    }

    private static func isBlank(_ content: NSRange, in storage: NSAttributedString) -> Bool {
        !(storage.string as NSString).substring(with: content).contains { !$0.isWhitespace }
    }

    private static func nextNonBlankIsCode(after index: Int, in analyses: [ParagraphAnalysis], storage: NSAttributedString) -> Bool {
        for analysis in analyses[(index + 1)...] {
            let content = contentRange(of: analysis.range, in: storage)
            guard !isBlank(content, in: storage) else { continue }
            if let intent = presentationIntent(in: content, storage: storage), intent.level != nil || intent.isCode {
                return intent.isCode
            }
            return fontProfile(in: content, storage: storage).isMonospace
        }
        return false
    }

    private static func dominantFontSize(in storage: NSAttributedString) -> CGFloat? {
        var counts: [CGFloat: Int] = [:]
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            guard let font = value as? PlatformFont else { return }
            counts[font.pointSize, default: 0] += run.length
        }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    private func paragraphLeaf(
        content: NSRange,
        storage: NSAttributedString,
        bodySize: CGFloat?,
        openCodeGroup: inout GroupToken?
    ) -> MarkdownBlock.Leaf {
        if let intent = Self.presentationIntent(in: content, storage: storage) {
            if let level = intent.level {
                openCodeGroup = nil
                return .heading(level: level)
            }
            if intent.isCode {
                let group = openCodeGroup ?? GroupToken.mint()
                openCodeGroup = group
                return .code(language: intent.language, group: group)
            }
        }
        let profile = Self.fontProfile(in: content, storage: storage)
        if profile.isMonospace {
            let group = openCodeGroup ?? GroupToken.mint()
            openCodeGroup = group
            return .code(language: nil, group: group)
        }
        openCodeGroup = nil
        if inferHeadings, profile.isBold, let size = profile.minimumSize, let bodySize, bodySize > 0,
           !(storage.string as NSString).substring(with: content).contains(MarkdownBreak.character) {
            let ratio = size / bodySize
            if ratio >= 1.8 { return .heading(level: 1) }
            if ratio >= 1.4 { return .heading(level: 2) }
            if ratio >= 1.15 { return .heading(level: 3) }
        }
        return .paragraph
    }

    private struct FontProfile {
        var isMonospace = false
        var isBold = false
        var minimumSize: CGFloat?
    }

    private static func fontProfile(in content: NSRange, storage: NSAttributedString) -> FontProfile {
        let ns = storage.string as NSString
        var monospace = true
        var bold = true
        var minimum: CGFloat?
        var sawText = false
        storage.enumerateAttribute(.font, in: content) { value, run, stop in
            let text = ns.substring(with: run)
            guard text.contains(where: { !$0.isWhitespace }) else { return }
            sawText = true
            guard let font = value as? PlatformFont else {
                monospace = false
                bold = false
                stop.pointee = true
                return
            }
            if !font.isMonospace { monospace = false }
            if !font.fontTraits.contains(.bold) { bold = false }
            minimum = min(minimum ?? font.pointSize, font.pointSize)
        }
        guard sawText else { return FontProfile() }
        return FontProfile(isMonospace: monospace, isBold: bold, minimumSize: minimum)
    }

    private struct BlockIntent {
        var level: Int?
        var isCode = false
        var language: String?
    }

    private static func presentationIntent(in content: NSRange, storage: NSAttributedString) -> BlockIntent? {
        guard content.length > 0,
              let intent = storage.attribute(.presentationIntentAttributeName, at: content.location, effectiveRange: nil) as? PresentationIntent
        else { return nil }
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return BlockIntent(level: max(1, min(6, level)))
            case .codeBlock(let hint):
                return BlockIntent(isCode: true, language: hint?.isEmpty == false ? hint : nil)
            default:
                continue
            }
        }
        return nil
    }

    private func copyInlineAttributes(
        from source: NSAttributedString,
        to output: NSMutableAttributedString,
        content: NSRange,
        block: MarkdownBlock
    ) {
        guard content.length > 0 else { return }
        let suppressBold = block.headingLevel != nil
        source.enumerateAttributes(in: content) { attributes, run, _ in
            var marks: MarkdownInlineIntent = []
            if !block.isCode {
                if let font = attributes[.font] as? PlatformFont {
                    let traits = font.fontTraits
                    if traits.contains(.bold), !suppressBold { marks.insert(.stronglyEmphasized) }
                    if traits.contains(.italic) { marks.insert(.emphasized) }
                    if font.isMonospace { marks.insert(.code) }
                }
                if let strike = attributes[.strikethroughStyle] as? NSNumber, strike.intValue != 0 {
                    marks.insert(.strikethrough)
                }
                if let foreign = MarkdownInlineIntent(attributeValue: attributes[.inlinePresentationIntent]) {
                    marks.formUnion(foreign.intersection(.markdownMarks))
                }
                if let ours = MarkdownInlineIntent(attributeValue: attributes[.markdownInlineIntent]) {
                    marks.formUnion(ours.intersection(.markdownMarks.union(.softBreak)))
                }
                if suppressBold { marks.remove(.stronglyEmphasized) }
            }
            if !marks.isEmpty {
                output.addAttribute(.markdownInlineIntent, value: marks.attributeValue, range: run)
            }
            if !block.isCode, let link = attributes[.link] {
                output.addAttribute(.link, value: link, range: run)
            }
            if let attachment = attributes[.attachment] as? ProseSourceAttachment {
                output.addAttribute(.attachment, value: attachment, range: run)
            }
            if let literal = attributes[.markdownLiteral] as? String, !block.isCode || SeparatorLiteral.isSource(literal) {
                output.addAttribute(.markdownLiteral, value: literal, range: run)
            }
            #if canImport(AppKit) && os(macOS)
            if let alternatives = attributes[.textAlternatives] {
                output.addAttribute(.textAlternatives, value: alternatives, range: run)
            }
            #endif
        }
    }
}
