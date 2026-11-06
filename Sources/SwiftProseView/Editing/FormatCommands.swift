import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension EditorController {
    public func perform(_ action: EditorAction) {
        guard canPerform(action) else { return }
        switch action {
        case .bold: toggleMark(.stronglyEmphasized)
        case .italic: toggleMark(.emphasized)
        case .strikethrough: toggleMark(.strikethrough)
        case .codeSpan: toggleMark(.code)
        case .heading(let level): toggleHeading(level)
        case .unorderedList: toggleList(ordered: false)
        case .orderedList: toggleList(ordered: true)
        case .taskList: toggleTaskList()
        case .blockquote: toggleQuote()
        case .codeBlock: toggleCodeBlock()
        case .link(let url, let label): applyLinkAction(url: url, label: label)
        case .horizontalRule: insertHorizontalRule()
        case .indent: _ = indentList(selectedParagraphs(in: currentSelection), actionName: "Indent")
        case .outdent: _ = outdentList(selectedParagraphs(in: currentSelection), actionName: "Outdent")
        case .insertTable, .insertTableRowAbove, .insertTableRowBelow, .insertTableColumnBefore,
             .insertTableColumnAfter, .deleteTableRow, .deleteTableColumn, .setTableColumnAlignment,
             .deleteTable, .editTableStructure:
            performTableAction(action)
        }
    }

    public func canPerform(_ action: EditorAction) -> Bool {
        guard isEditable else { return false }
        let paragraphs = selectedParagraphs(in: currentSelection)
        switch action {
        case .bold, .italic, .strikethrough, .codeSpan, .link:
            return paragraphs.contains { !$0.block.isCode && !$0.block.isAtom }
        case .heading, .unorderedList, .orderedList, .taskList, .blockquote, .codeBlock:
            return paragraphs.contains { !$0.block.excludesBlockFormatting }
        case .horizontalRule:
            return !paragraphs.contains { $0.block.isTableRow }
        case .indent, .outdent:
            return paragraphs.allSatisfy { $0.block.isListItem }
        case .insertTable, .insertTableRowAbove, .insertTableRowBelow, .insertTableColumnBefore,
             .insertTableColumnAfter, .deleteTableRow, .deleteTableColumn, .setTableColumnAlignment,
             .deleteTable, .editTableStructure:
            return canPerformTableAction(action)
        }
    }

    public func isActive(_ action: EditorAction) -> Bool {
        if case .setTableColumnAlignment(let alignment) = action {
            return currentTableColumnAlignment() == alignment
        }
        let selection = currentSelection
        let paragraphs = selectedParagraphs(in: selection).filter { !$0.block.isAtom }
        guard !paragraphs.isEmpty else { return false }
        switch action {
        case .bold: return markIsActive(.stronglyEmphasized, in: selection)
        case .italic: return markIsActive(.emphasized, in: selection)
        case .strikethrough: return markIsActive(.strikethrough, in: selection)
        case .codeSpan: return markIsActive(.code, in: selection)
        case .heading(let level): return paragraphs.allSatisfy { $0.block.headingLevel == level }
        case .unorderedList: return paragraphs.allSatisfy { innermostList($0)?.hasOrderedMarker == false && $0.block.task == nil }
        case .orderedList: return paragraphs.allSatisfy { innermostList($0)?.hasOrderedMarker == true }
        case .taskList: return paragraphs.allSatisfy { $0.block.task != nil }
        case .blockquote: return paragraphs.allSatisfy { $0.block.isInQuote }
        case .codeBlock: return paragraphs.allSatisfy { $0.block.isCode }
        case .link: return selection.length == 0
            ? (selection.location > 0 && textStorage.markdownLink(at: selection.location - 1) != nil)
            : textStorage.markdownLink(at: selection.location) != nil
        case .horizontalRule, .indent, .outdent: return false
        case .insertTable, .insertTableRowAbove, .insertTableRowBelow, .insertTableColumnBefore,
             .insertTableColumnAfter, .deleteTableRow, .deleteTableColumn, .setTableColumnAlignment,
             .deleteTable, .editTableStructure:
            return false
        }
    }

    public func activeActionIDs() -> Set<String> {
        let candidates: [EditorAction] = [
            .bold, .italic, .strikethrough, .codeSpan,
            .heading(level: 1), .heading(level: 2), .heading(level: 3),
            .heading(level: 4), .heading(level: 5), .heading(level: 6),
            .unorderedList, .orderedList, .taskList, .blockquote, .codeBlock, .link,
            .setTableColumnAlignment(.none), .setTableColumnAlignment(.left),
            .setTableColumnAlignment(.center), .setTableColumnAlignment(.right)
        ]
        return Set(candidates.filter(isActive).map(\.stableID))
    }

    func innermostList(_ info: ParagraphInfo) -> NSTextList? {
        effectiveLists(info).last
    }

    func markIsActive(_ mark: MarkdownInlineIntent, in selection: NSRange) -> Bool {
        if selection.length == 0 {
            return hostTypingAttributes.markdownInlineIntent.contains(mark)
                || (hostTextView == nil && selection.location > 0
                    && textStorage.markdownInlineIntent(at: selection.location - 1).contains(mark))
        }
        let ranges = markableRanges(in: selection)
        guard !ranges.isEmpty else { return false }
        return ranges.allSatisfy { range in
            var all = true
            textStorage.enumerateAttribute(.markdownInlineIntent, in: range) { value, _, stop in
                if !(MarkdownInlineIntent(attributeValue: value) ?? []).contains(mark) {
                    all = false
                    stop.pointee = true
                }
            }
            return all
        }
    }

    func markableRanges(in selection: NSRange) -> [NSRange] {
        let ns = textStorage.string as NSString
        var ranges: [NSRange] = []
        for info in selectedParagraphs(in: selection) where !info.block.isCode && !info.block.isAtom {
            let overlap = NSIntersectionRange(info.content, selection)
            guard overlap.length > 0 else { continue }
            var start = overlap.location
            var end = NSMaxRange(overlap)
            while start < end, Self.isMarkBoundary(ns.character(at: start)) { start += 1 }
            while end > start, Self.isMarkBoundary(ns.character(at: end - 1)) { end -= 1 }
            if end > start { ranges.append(NSRange(location: start, length: end - start)) }
        }
        return ranges
    }

    static func isMarkBoundary(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == MarkdownBreak.utf16
    }

    func toggleMark(_ mark: MarkdownInlineIntent) {
        let selection = currentSelection
        if selection.length == 0 {
            var attributes = hostTypingAttributes
            if attributes.markdownBlock == nil { attributes = typingAttributes(at: selection.location) }
            var intent = attributes.markdownInlineIntent
            if intent.contains(mark) { intent.remove(mark) } else { intent.insert(mark) }
            let info = paragraphInfo(at: selection.location)
            guard !info.block.isCode else { return }
            var updated = typingAttributes(for: info.block, textLists: info.lists, intent: intent.intersection(.markdownMarks))
            if let link = attributes[.link] { updated[.link] = link }
            applyTypingAttributes(updated)
            return
        }
        let ranges = markableRanges(in: selection)
        guard let first = ranges.first, let last = ranges.last else { return }
        let removing = markIsActive(mark, in: selection)
        let union = NSUnionRange(first, last)
        editAttributes(in: union, actionName: InputRules.actionName(for: mark)) { storage in
            for range in ranges {
                var updates: [(NSRange, MarkdownInlineIntent)] = []
                storage.enumerateAttribute(.markdownInlineIntent, in: range) { value, run, _ in
                    var intent = MarkdownInlineIntent(attributeValue: value) ?? []
                    if removing { intent.remove(mark) } else { intent.insert(mark) }
                    updates.append((run, intent))
                }
                for (run, intent) in updates {
                    if intent.isEmpty {
                        storage.removeAttribute(.markdownInlineIntent, range: run)
                    } else {
                        storage.addAttribute(.markdownInlineIntent, value: intent.attributeValue, range: run)
                    }
                }
                if mark == .code, !removing {
                    SeparatorLiteral.removeOtherLiterals(in: storage, range: range)
                }
            }
        }
    }

    func toggleHeading(_ level: Int) {
        let paragraphs = selectedParagraphs(in: currentSelection).filter { !$0.block.excludesBlockFormatting }
        let removing = level < 1 || paragraphs.allSatisfy { $0.block.headingLevel == level }
        _ = rewriteParagraphs(paragraphs, actionName: "Heading") { info in
            let leaf: MarkdownBlock.Leaf = removing ? .paragraph : .heading(level: level)
            return (info.block.with(leaf: leaf).with(task: removing ? info.block.task : nil), info.lists)
        }
    }

    func toggleList(ordered: Bool) {
        let selected = selectedParagraphs(in: currentSelection).filter { !$0.block.excludesBlockFormatting }
        let depth = max(1, selected.map { effectiveLists($0).count }.min() ?? 1)
        let paragraphs = expandedToWholeItems(selected, atDepth: depth)
        guard let first = paragraphs.first else { return }
        let removing = paragraphs.allSatisfy { info in
            let lists = effectiveLists(info)
            return lists.count >= depth && lists[depth - 1].hasOrderedMarker == ordered
                && (info.block.task == nil || ordered || lists.count > depth)
        }
        let actionName = ordered ? "Numbered List" : "Bulleted List"
        if removing {
            _ = removeList(atDepth: depth, from: paragraphs, actionName: actionName)
            return
        }
        let base = effectiveLists(first).prefix(depth - 1)
        let reuse = previousParagraphInfo(before: first).flatMap { previous -> NSTextList? in
            let lists = effectiveLists(previous)
            guard lists.count >= depth, lists[depth - 1].hasOrderedMarker == ordered,
                  zip(lists, base).allSatisfy({ $0 === $1 }) else { return nil }
            return lists[depth - 1]
        }
        let fresh = reuse ?? LoaderStructure.makeList(ordered: ordered, start: 1, depth: depth)
        _ = rewriteParagraphs(paragraphs, actionName: actionName) { info in
            let effective = self.effectiveLists(info)
            var lists = info.lists
            var containers = info.block.containers
            var task = info.block.task
            var isContinuation = info.block.isContinuation
            if effective.count >= depth {
                let current = effective[depth - 1]
                if let index = lists.firstIndex(where: { $0 === current }) { lists[index] = fresh }
                if effective.count == depth { task = nil }
            } else {
                lists.append(fresh)
                containers.append(.listItem)
                isContinuation = false
            }
            return (MarkdownBlock(leaf: info.block.leaf, containers: containers, isContinuation: isContinuation, task: task), lists)
        }
    }

    func removeList(atDepth depth: Int, from paragraphs: [ParagraphInfo], actionName: String) -> Bool {
        rewriteParagraphs(paragraphs, actionName: actionName) { info in
            let effective = self.effectiveLists(info)
            guard effective.count >= depth else { return nil }
            let removed = effective[depth - 1]
            var lists = info.lists
            lists.removeAll { $0 === removed }
            var containers = info.block.containers
            let index = Self.containerIndex(afterListItem: depth, in: containers) - 1
            if index >= 0, index < containers.count, containers[index] == .listItem {
                containers.remove(at: index)
            }
            let stillList = containers.contains(.listItem)
            return (MarkdownBlock(
                leaf: info.block.leaf,
                containers: containers,
                isContinuation: stillList ? info.block.isContinuation : false,
                task: stillList ? info.block.task : nil
            ), lists)
        }
    }

    func removeInnermostList(_ paragraphs: [ParagraphInfo], actionName: String) -> Bool {
        rewriteParagraphs(paragraphs, actionName: actionName) { info in
            guard let current = self.innermostList(info) else { return nil }
            var lists = info.lists
            lists.removeAll { $0 === current }
            var containers = info.block.containers
            if let index = containers.lastIndex(of: .listItem) { containers.remove(at: index) }
            let stillList = containers.contains(.listItem)
            return (MarkdownBlock(
                leaf: info.block.leaf,
                containers: containers,
                isContinuation: stillList ? info.block.isContinuation : false,
                task: stillList ? info.block.task : nil
            ), lists)
        }
    }

    func toggleTaskList() {
        let paragraphs = selectedParagraphs(in: currentSelection).filter { !$0.block.excludesBlockFormatting }
        guard let first = paragraphs.first else { return }
        if paragraphs.allSatisfy({ $0.block.task != nil }) {
            _ = removeInnermostList(paragraphs, actionName: "Task List")
            return
        }
        let fresh = LoaderStructure.makeList(ordered: false, start: 1, depth: max(1, effectiveLists(first).count))
        _ = rewriteParagraphs(paragraphs, actionName: "Task List") { info in
            var lists = info.lists
            var containers = info.block.containers
            if self.innermostList(info) == nil {
                lists.append(fresh)
                containers.append(.listItem)
            }
            return (MarkdownBlock(leaf: .paragraph, containers: containers, isContinuation: false, task: info.block.task ?? .unchecked), lists)
        }
    }

    func toggleQuote() {
        let paragraphs = selectedParagraphs(in: currentSelection).filter { !$0.block.excludesBlockFormatting }
        let removing = paragraphs.allSatisfy { $0.block.isInQuote }
        let token = GroupToken.mint()
        _ = rewriteParagraphs(paragraphs, actionName: "Quote") { info in
            var containers = info.block.containers
            if removing {
                guard let index = containers.lastIndex(where: Self.isQuote) else { return nil }
                containers.remove(at: index)
            } else {
                containers.insert(.quote(token), at: 0)
            }
            return (info.block.with(containers: containers), info.lists)
        }
    }

    func toggleCodeBlock() {
        let paragraphs = selectedParagraphs(in: currentSelection).filter { !$0.block.excludesBlockFormatting }
        let removing = paragraphs.allSatisfy { $0.block.isCode }
        let existing = paragraphs.first { $0.block.isCode }?.block
        let group = existing?.codeGroup ?? GroupToken.mint()
        let language = existing?.codeLanguage
        let style = existing?.codeStyle ?? .fenced
        _ = rewriteParagraphs(paragraphs, actionName: "Code Block") { info in
            let leaf: MarkdownBlock.Leaf = removing ? .paragraph : .code(language: language, group: group, style: style)
            return (info.block.with(leaf: leaf).with(task: removing ? info.block.task : nil), info.lists)
        }
    }

    func applyLinkAction(url: String?, label: String?) {
        let selection = currentSelection
        if let url, !url.isEmpty {
            if selection.length > 0 {
                setLink(url, in: selection)
            } else {
                insertLink(label: label ?? url, url: url)
            }
            return
        }
        let probe = selection.length > 0 ? selection.location : max(0, selection.location - 1)
        guard textStorage.markdownLink(at: probe) != nil else {
            let ns = textStorage.string as NSString
            let selected = selection.length > 0 ? ns.substring(with: Normalizer.clamp(selection, to: ns.length)) : ""
            let href = Self.looksLikeURL(selected) ? selected : "url"
            insertLink(label: label ?? "link", url: href)
            return
        }
        var effective = NSRange()
        _ = textStorage.attribute(
            .link,
            at: probe,
            longestEffectiveRange: &effective,
            in: paragraphInfo(at: probe).content
        )
        setLink(nil, in: selection.length > 0 ? selection : effective)
    }

    static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        if trimmed.lowercased().hasPrefix("www.") { return true }
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    @discardableResult
    public func setLink(_ url: String?, in range: NSRange, label: String = "Link") -> Bool {
        let target = Normalizer.clamp(range, to: textStorage.length)
        guard target.length > 0, isEditable else { return false }
        let value: Any? = url.map { URL(string: $0).map { $0 as Any } ?? $0 }
        return editAttributes(in: target, actionName: label) { storage in
            if let value {
                storage.addAttribute(.link, value: value, range: target)
            } else {
                storage.removeAttribute(.link, range: target)
            }
        }
    }

    @discardableResult
    public func insertLink(label: String, url: String) -> Bool {
        guard isEditable else { return false }
        let selection = currentSelection
        let ns = textStorage.string as NSString
        let selected = selection.length > 0 ? ns.substring(with: Normalizer.clamp(selection, to: ns.length)) : ""
        let text = selected.isEmpty ? label : selected
        guard !text.isEmpty else { return false }
        let info = paragraphInfo(at: selection.location)
        guard !info.block.isCode else {
            return replaceText(in: selection, with: text, label: "Insert Link")
        }
        var attributes = typingAttributes(at: selection.location)
        attributes[.link] = URL(string: url) ?? url as Any
        let replacement = NSAttributedString(string: text, attributes: attributes)
        let end = selection.location + replacement.length
        let applied = replace(selection, with: replacement, actionName: "Insert Link", selection: NSRange(location: end, length: 0))
        if applied {
            var typing = attributes
            typing.removeValue(forKey: .link)
            applyTypingAttributes(typing)
        }
        return applied
    }

    @discardableResult
    public func replaceText(in range: NSRange, with text: String, label: String = "Replace") -> Bool {
        guard isEditable else { return false }
        let target = Normalizer.clamp(range, to: textStorage.length)
        let normalized = PasteSanitizer.normalizeLineEndings(text)
        let replacement = NSAttributedString(string: normalized, attributes: insertionAttributes(replacing: target))
        let end = target.location + replacement.length
        return replace(target, with: replacement, actionName: label, selection: NSRange(location: end, length: 0))
    }

    @discardableResult
    public func insertInlineContent(
        _ content: ProseInlineContent,
        markdownSource: String,
        replacing range: NSRange,
        trailingText: String = " ",
        label: String = "Insert"
    ) -> Bool {
        guard isEditable else { return false }
        let target = Normalizer.clamp(range, to: textStorage.length)
        if paragraphInfo(at: target.location).block.isCode || isLocationInCode(target.location) {
            return replaceText(in: target, with: markdownSource + trailingText, label: label)
        }
        let attachment: NSTextAttachment & ProseSourceAttachment =
            (inlineContentProvider?(content) as? NSTextAttachment & ProseSourceAttachment)
            ?? ChipAttachment.make(for: content)
        attachment.markdownSource = markdownSource
        if attachment.contentKind.isEmpty { attachment.contentKind = content.kind }
        let attributes = insertionAttributes(replacing: target)
        let replacement = NSMutableAttributedString(string: "\u{FFFC}", attributes: attributes)
        replacement.addAttribute(.attachment, value: attachment, range: NSRange(location: 0, length: 1))
        replacement.append(NSAttributedString(string: trailingText, attributes: attributes))
        let end = target.location + replacement.length
        return replace(target, with: replacement, actionName: label, selection: NSRange(location: end, length: 0))
    }

    private func insertionAttributes(replacing target: NSRange) -> [NSAttributedString.Key: Any] {
        let probe = target.length > 0 ? target.location : max(0, target.location - 1)
        var attributes: [NSAttributedString.Key: Any]
        if probe < textStorage.length, !(target.length == 0 && target.location == paragraphInfo(at: target.location).content.location) {
            attributes = textStorage.attributes(at: probe, effectiveRange: nil)
        } else {
            attributes = typingAttributes(at: target.location)
        }
        attributes.removeValue(forKey: .link)
        attributes.removeValue(forKey: .markdownLiteral)
        attributes.removeValue(forKey: .attachment)
        if paragraphInfo(at: target.location).block.isCode {
            attributes.markdownInlineIntent = []
        } else {
            attributes.markdownInlineIntent = attributes.markdownInlineIntent.intersection(.markdownMarks)
        }
        return attributes
    }

    func insertHorizontalRule() {
        let selection = currentSelection
        let info = paragraphInfo(at: selection.location)
        let rule = makeRuleAttachment(source: "---")
        let atomBlock = MarkdownBlock(leaf: .thematicBreak, containers: info.block.containers, isContinuation: info.block.isListItem)
        let after = MarkdownBlock(containers: info.block.containers, isContinuation: info.block.isListItem)
        let atom = NSMutableAttributedString(attachment: rule)
        atom.addAttributes(paragraphAttributes(for: atomBlock, textLists: info.lists), range: NSRange(location: 0, length: 1))
        let replacement = NSMutableAttributedString()
        let target: NSRange
        let caret: Int
        if info.isEmpty {
            target = info.range
            replacement.append(atom)
            replacement.append(separator(block: atomBlock, textLists: info.lists))
            replacement.append(separator(block: after, textLists: info.lists))
            if !info.hasSeparator { replacement.deleteCharacters(in: NSRange(location: replacement.length - 1, length: 1)) }
            caret = info.range.location + 2
        } else {
            target = NSRange(location: NSMaxRange(info.content), length: info.hasSeparator ? 1 : 0)
            replacement.append(separator(block: info.block, textLists: info.lists))
            replacement.append(atom)
            replacement.append(separator(block: atomBlock, textLists: info.lists))
            if info.hasSeparator { replacement.append(separator(block: after, textLists: info.lists)) }
            caret = target.location + 3
        }
        let applied = replace(target, with: replacement, actionName: "Horizontal Rule", selection: NSRange(location: caret, length: 0))
        if applied {
            if info.hasSeparator {
                applyTypingAttributes(typingAttributes(for: after, textLists: info.lists))
            } else {
                applyTrailingBlock(after, textLists: info.lists, actionName: "Horizontal Rule")
            }
        }
    }

    @discardableResult
    public func toggleCheckbox(at index: Int) -> Bool {
        guard isEditable || allowsCheckboxToggle else { return false }
        let info = paragraphInfo(at: index)
        guard !info.isTrailingEmpty, index == info.content.location, info.block.isListItemStart,
              let task = info.block.task else { return false }
        let toggled = info.block.with(task: task.isChecked ? .unchecked : .checked)
        return editAttributes(in: info.range, actionName: task.isChecked ? "Uncheck" : "Check", ignoringEditability: true) { storage in
            storage.addAttribute(.markdownBlock, value: toggled, range: info.range)
        }
    }

    func fontTraitActions(converting convert: (PlatformFont) -> PlatformFont) -> [EditorAction] {
        let plain = restyler.theme.bodyFont
        let rich = plain.withFontTraits([.bold, .italic])
        let plainTraits = convert(plain).fontTraits
        let richTraits = convert(rich).fontTraits
        var actions: [EditorAction] = []
        if plainTraits.contains(.bold) || !richTraits.contains(.bold) { actions.append(.bold) }
        if plainTraits.contains(.italic) || !richTraits.contains(.italic) { actions.append(.italic) }
        return actions
    }

    func makeRuleAttachment(source: String) -> HorizontalRuleAttachment {
        let rule = HorizontalRuleAttachment(color: theme.horizontalRule.color, thickness: theme.horizontalRule.thickness)
        rule.markdownSource = source
        return rule
    }
}
