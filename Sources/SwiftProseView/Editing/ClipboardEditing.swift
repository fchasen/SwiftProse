import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct PastePayload {
    var markdown: String?
    var plainText: String?
    var richText: NSAttributedString?
    var forcePlain = false

    var isEmpty: Bool {
        (markdown ?? "").isEmpty && (plainText ?? "").isEmpty && (richText?.length ?? 0) == 0
    }

    var anyText: String? {
        if let markdown, !markdown.isEmpty { return markdown }
        if let plainText, !plainText.isEmpty { return plainText }
        if let richText, richText.length > 0 { return richText.string }
        return nil
    }
}

extension EditorController {
    public static let markdownPasteboardType = "dev.swiftprose.markdown"

    @discardableResult
    public func insertMarkdown(_ markdown: String, label: String = "Insert") -> Bool {
        insertMarkdown(markdown, replacing: currentSelection, label: label)
    }

    @discardableResult
    public func insertMarkdown(_ markdown: String, replacing range: NSRange, label: String = "Insert") -> Bool {
        guard isEditable, !markdown.isEmpty else { return false }
        let target = Normalizer.clamp(range, to: textStorage.length)
        if isLocationInCode(target.location) {
            return insertLiteral(markdown, replacing: target, actionName: label)
        }
        return insertParsedMarkdown(markdown, replacing: target, actionName: label)
    }

    func markdownForCopy(range: NSRange) -> String {
        let target = Normalizer.clamp(range, to: textStorage.length)
        guard target.length > 0 else { return "" }
        let paragraphs = textStorage.markdownParagraphRanges(in: target).filter { $0.length > 0 }
        if paragraphs.count == 1, let paragraph = paragraphs.first {
            let info = paragraphInfo(at: paragraph.location)
            let coversContent = target.location <= info.content.location && NSMaxRange(target) >= NSMaxRange(info.content)
            if !coversContent {
                let clipped = NSIntersectionRange(target, info.content)
                let fragment = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: clipped))
                if info.block.isCode || (info.block.isAtom && fragment.proseSourceAttachment(at: 0) == nil) {
                    return fragment.string.replacingOccurrences(of: MarkdownBreak.string, with: "\n")
                }
                if info.block.isTableRow, fragment.string.contains(MarkdownTableSeparator.character) {
                    return MarkdownWriter().markdown(from: textStorage, range: target)
                }
                let full = NSRange(location: 0, length: fragment.length)
                fragment.addAttribute(.markdownBlock, value: MarkdownBlock.paragraph, range: full)
                fragment.addAttribute(.paragraphStyle, value: NSParagraphStyle(), range: full)
                return MarkdownWriter().markdown(from: fragment)
            }
        }
        let drop = enclosingListLevels(of: paragraphs)
        guard drop > 0 else { return MarkdownWriter().markdown(from: textStorage, range: target) }
        let fragment = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: target))
        for paragraph in fragment.markdownParagraphRanges().filter({ $0.length > 0 }) {
            let block = fragment.markdownBlock(at: paragraph.location) ?? .paragraph
            var containers: [MarkdownBlock.Container] = []
            var remaining = drop
            for container in block.containers {
                if container == .listItem, remaining > 0 {
                    remaining -= 1
                } else {
                    containers.append(container)
                }
            }
            let lists = Array(Self.textLists(in: fragment, at: paragraph.location).dropFirst(drop))
            let adjusted = block.with(containers: containers)
            fragment.addAttribute(.markdownBlock, value: adjusted, range: paragraph)
            fragment.addAttribute(.paragraphStyle, value: restyler.paragraphStyle(for: adjusted, textLists: lists), range: paragraph)
        }
        return MarkdownWriter().markdown(from: fragment)
    }

    private func enclosingListLevels(of paragraphs: [NSRange]) -> Int {
        guard let first = paragraphs.first, let firstBlock = textStorage.markdownBlock(at: first.location) else { return 0 }
        let firstLists = Self.textLists(in: textStorage, at: first.location)
        var drop = min(firstLists.count, firstBlock.isListItemStart ? firstBlock.listDepth - 1 : firstBlock.listDepth)
        for paragraph in paragraphs.dropFirst() where drop > 0 {
            let block = textStorage.markdownBlock(at: paragraph.location) ?? .paragraph
            let lists = Self.textLists(in: textStorage, at: paragraph.location)
            let shared = zip(firstLists, lists).prefix { $0 === $1 }.count
            drop = min(drop, shared)
            if block.isListItemStart {
                drop = min(drop, block.listDepth - 1)
            }
        }
        return max(0, drop)
    }

    @discardableResult
    func deleteForCut(_ range: NSRange) -> Bool {
        let target = Normalizer.clamp(range, to: textStorage.length)
        guard target.length > 0 else { return false }
        if editTouchesTable(target) {
            return replaceRespectingTables(target, with: NSAttributedString(), actionName: "Cut")
        }
        return replace(target, with: NSAttributedString(), actionName: "Cut", selection: NSRange(location: target.location, length: 0))
    }

    func copySelection(_ range: NSRange) -> Bool {
        #if canImport(UIKit) && os(iOS)
        let target = Normalizer.clamp(range, to: textStorage.length)
        guard target.length > 0 else { return false }
        let markdown = markdownForCopy(range: target)
        UIPasteboard.general.items = [[
            "public.utf8-plain-text": markdown,
            Self.markdownPasteboardType: Data(markdown.utf8)
        ]]
        return true
        #else
        return false
        #endif
    }

    func dispatchPaste(_ event: PasteEvent) -> Bool {
        var payload = PastePayload(plainText: event.text, forcePlain: event.plainText)
        if !event.plainText, let html = event.html, !html.isEmpty, let rich = Self.attributedString(fromHTML: html) {
            payload.richText = rich
        }
        return paste(payload, replacing: event.selection)
    }

    @discardableResult
    func paste(_ payload: PastePayload, replacing range: NSRange) -> Bool {
        guard isEditable, !payload.isEmpty else { return false }
        harnessRouteProbe?("paste")
        let target = Normalizer.clamp(range, to: textStorage.length)
        if payload.forcePlain || isLocationInCode(target.location) {
            guard let text = payload.plainText ?? payload.anyText else { return false }
            return insertLiteral(text, replacing: target, actionName: "Paste")
        }
        if let markdown = payload.markdown, !markdown.isEmpty {
            return insertParsedMarkdown(markdown, replacing: target, actionName: "Paste")
        }
        if let rich = payload.richText, rich.length > 0 {
            let fragment = PasteSanitizer().sanitize(rich)
            Self.trimTrailingSeparators(fragment)
            guard fragment.length > 0 else { return false }
            return insertFragment(fragment, replacing: target, actionName: "Paste")
        }
        if let text = payload.plainText, !text.isEmpty {
            return insertParsedMarkdown(text, replacing: target, actionName: "Paste")
        }
        return false
    }

    func insertParsedMarkdown(_ markdown: String, replacing range: NSRange, actionName: String) -> Bool {
        let normalized = PasteSanitizer.normalizeLineEndings(markdown)
        let loader = MarkdownLoader(inlineContentRules: inlineContentRules, inlineContentProvider: inlineContentProvider)
        var fragment = loader.load(normalized)
        Self.trimTrailingSeparators(fragment)
        if !normalized.contains("\n") {
            if let block = fragment.length > 0 ? fragment.markdownBlock(at: 0) : nil,
               !block.containers.isEmpty || block.headingLevel != nil,
               !replacesWholeParagraph(range),
               let escaped = Self.escapingLeadingBlockMarker(in: normalized) {
                fragment = loader.load(escaped.markdown)
                Self.trimTrailingSeparators(fragment)
                let startsParagraph = range.location <= paragraphInfo(at: range.location).content.location
                if !startsParagraph, escaped.index < fragment.length, fragment.markdownLiteral(at: escaped.index) != nil {
                    fragment.removeAttribute(.markdownLiteral, range: NSRange(location: escaped.index, length: 1))
                }
            }
            let leading = String(normalized.prefix(while: { $0 == " " || $0 == "\t" }))
            let trailing = String(normalized.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            if leading.count < normalized.count {
                let block = fragment.length > 0 ? fragment.markdownBlock(at: 0) ?? .paragraph : .paragraph
                if !leading.isEmpty, !fragment.string.hasPrefix(leading) {
                    fragment.insert(NSAttributedString(string: leading, attributes: [.markdownBlock: block]), at: 0)
                }
                if !trailing.isEmpty, !fragment.string.hasSuffix(trailing) {
                    fragment.append(NSAttributedString(string: trailing, attributes: [.markdownBlock: block]))
                }
            }
        }
        guard fragment.length > 0 else {
            return insertLiteral(normalized, replacing: range, actionName: actionName)
        }
        return insertFragment(fragment, replacing: range, actionName: actionName)
    }

    private func replacesWholeParagraph(_ range: NSRange) -> Bool {
        let target = Normalizer.clamp(range, to: textStorage.length)
        let context = paragraphInfo(at: target.location)
        let endContext = paragraphInfo(at: NSMaxRange(target))
        return target.location <= context.content.location
            && NSMaxRange(target) >= NSMaxRange(endContext.content)
            && endContext.range.location == context.range.location
    }

    private static func escapingLeadingBlockMarker(in line: String) -> (markdown: String, index: Int)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
        let start = index
        while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
        guard index < characters.count else { return nil }
        var escaped = characters
        escaped.insert("\\", at: index)
        let offset = String(characters[start..<index]).utf16.count
        return (String(escaped), offset)
    }

    func insertFragment(_ fragment: NSAttributedString, replacing range: NSRange, actionName: String) -> Bool {
        guard isEditable, fragment.length > 0 else { return false }
        let target = Normalizer.clamp(range, to: textStorage.length)
        if editTouchesTable(target) {
            return replaceRespectingTables(target, with: fragment, actionName: actionName)
        }
        let context = paragraphInfo(at: target.location)
        let isSingleParagraph = !fragment.string.contains("\n")
        let fragmentBlock = fragment.markdownBlock(at: 0) ?? .paragraph
        let inline = isSingleParagraph
            && (!replacesWholeParagraph(target) || (fragmentBlock.leaf == .paragraph && fragmentBlock.containers.isEmpty))

        let built: NSMutableAttributedString
        if inline {
            built = NSMutableAttributedString(attributedString: fragment)
            let full = NSRange(location: 0, length: built.length)
            let style = restyler.paragraphStyle(for: context.block, textLists: context.lists)
            built.addAttribute(.markdownBlock, value: context.block, range: full)
            built.addAttribute(.paragraphStyle, value: style, range: full)
        } else {
            built = contextualized(fragment, in: context)
            separateTableRows(in: built, replacing: target, context: context)
        }
        let end = target.location + built.length
        return replace(target, with: built, actionName: actionName, selection: NSRange(location: end, length: 0))
    }

    private func separateTableRows(in built: NSMutableAttributedString, replacing target: NSRange, context: ParagraphInfo) {
        guard built.length > 0 else { return }
        let ns = textStorage.string as NSString
        let lastParagraph = built.markdownParagraphRange(at: built.length - 1)
        if built.markdownBlock(at: lastParagraph.location)?.isTableRow == true,
           NSMaxRange(target) < ns.length, ns.character(at: NSMaxRange(target)) != MarkdownParagraph.separator {
            let attributes = built.attributes(at: lastParagraph.location, effectiveRange: nil)
            built.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        if built.markdownBlock(at: 0)?.isTableRow == true, target.location > context.content.location {
            built.insert(separator(block: context.block, textLists: context.lists), at: 0)
        }
    }

    private func contextualized(_ fragment: NSAttributedString, in context: ParagraphInfo) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(attributedString: fragment)
        var contextContainers = context.block.containers
        var contextLists = context.lists
        let hasListContext = context.block.isListItem
        let paragraphs = result.markdownParagraphRanges().filter { $0.length > 0 }
        if context.block.isListItemStart, contextContainers.last == .listItem, !contextLists.isEmpty,
           let first = paragraphs.first, result.markdownBlock(at: first.location)?.containers.first == .listItem {
            contextContainers.removeLast()
            contextLists.removeLast()
        }
        for (index, paragraph) in paragraphs.enumerated() {
            let block = result.markdownBlock(at: paragraph.location) ?? .paragraph
            let ownLists = Self.textLists(in: result, at: paragraph.location)
            let lists = contextLists + ownLists
            let containers = contextContainers + block.containers
            var isContinuation = block.isContinuation
            var task = block.task
            if index == 0 {
                if block.containers.isEmpty {
                    isContinuation = context.block.isContinuation
                    task = context.block.task ?? task
                }
            } else if hasListContext, !block.isListItem {
                isContinuation = true
            }
            let adjusted = MarkdownBlock(leaf: block.leaf, containers: containers, isContinuation: isContinuation, task: task)
            result.addAttribute(.markdownBlock, value: adjusted, range: paragraph)
            result.addAttribute(.paragraphStyle, value: restyler.paragraphStyle(for: adjusted, textLists: lists), range: paragraph)
        }
        return result
    }

    func insertLiteral(_ text: String, replacing range: NSRange, actionName: String) -> Bool {
        guard isEditable else { return false }
        let target = Normalizer.clamp(range, to: textStorage.length)
        let normalized = PasteSanitizer.normalizeLineEndings(text)
        guard !normalized.isEmpty else { return false }
        if editTouchesTable(target) {
            let attributes = adjustedTypingAttributes(typingAttributes(at: target.location))
            return replaceRespectingTables(target, with: NSAttributedString(string: normalized, attributes: attributes), actionName: actionName)
        }
        let context = paragraphInfo(at: target.location)
        let first = context.block
        let rest: MarkdownBlock
        if first.isCode {
            rest = first
        } else {
            rest = MarkdownBlock(
                leaf: first.headingLevel != nil ? .paragraph : first.leaf,
                containers: first.containers,
                isContinuation: first.isListItem ? first.isContinuation : false,
                task: first.task == nil ? nil : .unchecked
            )
        }
        var intent: MarkdownInlineIntent = []
        if !first.isCode, isLocationInCode(target.location) {
            intent = textStorage.markdownInlineIntent(at: target.location - 1).intersection(.markdownMarks)
        }
        let lines = normalized.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let block = index == 0 ? first : rest
            result.append(NSAttributedString(string: line, attributes: typingAttributes(for: block, textLists: context.lists, intent: intent)))
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: paragraphAttributes(for: block, textLists: context.lists)))
            }
        }
        let end = target.location + result.length
        return replace(target, with: result, actionName: actionName, selection: NSRange(location: end, length: 0))
    }

    static func trimTrailingSeparators(_ fragment: NSMutableAttributedString) {
        while fragment.length > 0, (fragment.string as NSString).character(at: fragment.length - 1) == MarkdownParagraph.separator {
            fragment.deleteCharacters(in: NSRange(location: fragment.length - 1, length: 1))
        }
    }

    static func attributedString(fromHTML html: String) -> NSAttributedString? {
        guard Thread.isMainThread, let data = html.data(using: .utf8) else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }

    func writingToolsIgnoredRanges(in enclosing: NSRange) -> [NSRange] {
        let target = Normalizer.clamp(enclosing, to: textStorage.length)
        guard target.length > 0 else { return [] }
        var ranges: [NSRange] = []
        func add(_ range: NSRange) {
            let clipped = NSIntersectionRange(range, target)
            guard clipped.length > 0 else { return }
            if let last = ranges.last, NSMaxRange(last) >= clipped.location {
                ranges[ranges.count - 1] = NSUnionRange(last, clipped)
            } else {
                ranges.append(clipped)
            }
        }
        textStorage.enumerateAttributes(in: target) { attributes, run, _ in
            if attributes.markdownBlock?.isCode == true || attributes.markdownBlock?.isAtom == true
                || attributes.markdownInlineIntent.contains(.code) || attributes[.attachment] != nil {
                add(run)
            }
        }
        let ns = textStorage.string as NSString
        for index in target.location..<NSMaxRange(target) {
            let unit = ns.character(at: index)
            guard unit == MarkdownTableSeparator.utf16 || unit == MarkdownParagraph.separator,
                  textStorage.markdownBlock(at: index)?.isTableRow == true else { continue }
            ranges.append(NSRange(location: index, length: 1))
        }
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    func writingToolsWillBegin() {
        isWritingToolsActive = true
        pendingInput = nil
    }

    func writingToolsDidEnd() {
        isWritingToolsActive = false
        guard textStorage.length > 0 else { return }
        withoutBinding {
            textStorage.beginEditing()
            normalizer.normalizeAll(textStorage, markedRange: hostMarkedRange)
            restyler.restyleAll(textStorage)
            codeHighlighting.resetAll(in: textStorage, baseColor: codeBaseColor)
            textStorage.endEditing()
        }
        scheduleBindingPush()
        repairTables()
    }
}
