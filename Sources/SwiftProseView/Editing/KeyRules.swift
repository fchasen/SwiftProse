import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension EditorController {
    var canApplyKeyRules: Bool {
        isEditable && !hostHasMarkedText && !isSettingMarkedText
    }

    func handleCommand(_ selector: Selector) -> Bool {
        switch NSStringFromSelector(selector) {
        case "insertNewlineIgnoringFieldEditor:", "insertParagraphSeparator:":
            return handleNewline()
        case "deleteBackwardByDecomposingPreviousCharacter:":
            return handleBackspace()
        case "deleteForward:":
            return handleForwardDelete()
        default:
            return false
        }
    }

    func handleNewline() -> Bool {
        guard canApplyKeyRules else { return false }
        if let handled = handleTableNewline() { return handled }
        let selection = currentSelection
        guard selection.length == 0 else { return false }
        let caret = selection.location
        let info = paragraphInfo(at: caret)

        if info.block.isAtom, !info.isTrailingEmpty {
            return insertParagraphBesideAtom(info, caret: caret, text: "")
        }
        if let handled = applyFenceRule(info, caret: caret) { return handled }
        if let handled = applyThematicBreakRule(info, caret: caret) { return handled }

        if info.block.isCode {
            return handleCodeNewline(info, caret: caret)
        }
        if info.block.isListItem, info.block.containers.last == .listItem {
            if let handled = handleListNewline(info, caret: caret) { return handled }
        }
        if info.block.containers.last.map(Self.isQuote) == true, info.isEmpty {
            return removeInnermostQuote(info, actionName: "Remove Quote")
        }
        if info.block.headingLevel != nil, caret == NSMaxRange(info.content), !info.isEmpty {
            return splitParagraph(info, at: caret, lowerBlock: info.block.with(leaf: .paragraph), actionName: "New Paragraph")
        }
        return false
    }

    func handleBackspace() -> Bool {
        guard canApplyKeyRules else { return false }
        let selection = currentSelection
        guard selection.length == 0 else { return false }
        let caret = selection.location
        if let handled = handleTableBackspace(at: caret) { return handled }
        let info = paragraphInfo(at: caret)

        if info.block.isAtom, !info.isTrailingEmpty, caret == info.content.location + 1 {
            return deleteAtomParagraph(info)
        }
        guard caret == info.content.location else { return false }

        if let previous = previousParagraphInfo(before: info), previous.block.isAtom, !info.block.isAtom {
            if info.isTrailingEmpty { return false }
            if info.isEmpty {
                return replace(
                    info.range,
                    with: NSAttributedString(),
                    actionName: "Delete",
                    selection: NSRange(location: NSMaxRange(previous.content), length: 0)
                )
            }
            return deleteAtomParagraph(previous)
        }
        if info.block.isListItemStart, info.block.task != nil {
            return setBlock(info.block.with(task: nil), for: info, actionName: "Remove Task")
        }
        if info.block.headingLevel != nil {
            return setBlock(info.block.with(leaf: .paragraph), for: info, actionName: "Paragraph")
        }
        if info.block.isCode {
            let previous = previousParagraphInfo(before: info)
            if previous?.block.codeGroup != info.block.codeGroup {
                return setBlock(info.block.with(leaf: .paragraph), for: info, actionName: "Paragraph")
            }
            return false
        }
        if let last = info.block.containers.last, Self.isQuote(last) {
            return removeInnermostQuote(info, actionName: "Remove Quote")
        }
        if info.block.isListItemStart, !usesNativeListEditing {
            return outdentList([info], actionName: "Outdent")
        }
        return false
    }

    func handleTab(backward: Bool) -> Bool {
        guard canApplyKeyRules else { return false }
        if let handled = handleTableTab(backward: backward) { return handled }
        let paragraphs = selectedParagraphs(in: currentSelection)
        guard !paragraphs.isEmpty, paragraphs.allSatisfy({ $0.block.isListItem && !$0.block.isCode }) else {
            return false
        }
        return backward ? outdentList(paragraphs, actionName: "Outdent") : indentList(paragraphs, actionName: "Indent")
    }

    var canExitCodeBlock: Bool {
        canApplyKeyRules && paragraphInfo(at: currentSelection.location).block.isCode
    }

    func exitCodeBlock() -> Bool {
        guard canApplyKeyRules else { return false }
        let caret = currentSelection.location
        var info = paragraphInfo(at: caret)
        guard let group = info.block.codeGroup else { return false }
        while let next = nextParagraphInfo(after: info), next.block.codeGroup == group {
            info = next
        }
        let lower = info.block.with(leaf: .paragraph).with(isContinuation: info.block.isListItem)
        return splitParagraph(info, at: NSMaxRange(info.content), lowerBlock: lower, actionName: "Exit Code Block")
    }

    func redirectTypingIntoAtom(range: NSRange, text: String) -> Bool {
        guard isEditable, range.length == 0, !text.contains("\n") else { return false }
        let info = paragraphInfo(at: range.location)
        guard info.block.isAtom, !info.isTrailingEmpty else { return false }
        guard range.location == info.content.location || range.location == info.content.location + 1 else { return false }
        return insertParagraphBesideAtom(info, caret: range.location, text: text)
    }

    static func isQuote(_ container: MarkdownBlock.Container) -> Bool {
        if case .quote = container { return true }
        return false
    }

    @discardableResult
    func applyTrailingBlock(_ block: MarkdownBlock, textLists: [NSTextList], actionName: String) -> Bool {
        guard textLists.contains(where: { !$0.markerFormat.rawValue.isEmpty }) else {
            applyTypingAttributes(typingAttributes(for: block, textLists: textLists))
            return true
        }
        let end = textStorage.length
        let applied = replace(
            NSRange(location: end, length: 0),
            with: separator(block: block, textLists: textLists),
            actionName: actionName,
            selection: NSRange(location: end, length: 0)
        )
        if applied { applyTypingAttributes(typingAttributes(for: block, textLists: textLists)) }
        return applied
    }

    func setBlock(_ block: MarkdownBlock, for info: ParagraphInfo, actionName: String) -> Bool {
        if info.isTrailingEmpty {
            return applyTrailingBlock(block, textLists: info.lists, actionName: actionName)
        }
        return editAttributes(in: info.range, actionName: actionName) { storage in
            storage.addAttribute(.markdownBlock, value: block, range: info.range)
        }
    }

    func setBlock(_ block: MarkdownBlock, textLists: [NSTextList], for info: ParagraphInfo, actionName: String) -> Bool {
        if info.isTrailingEmpty {
            return applyTrailingBlock(block, textLists: textLists, actionName: actionName)
        }
        let style = restyler.paragraphStyle(for: block, textLists: textLists)
        return editAttributes(in: info.range, actionName: actionName) { storage in
            storage.addAttribute(.markdownBlock, value: block, range: info.range)
            storage.addAttribute(.paragraphStyle, value: style, range: info.range)
        }
    }

    @discardableResult
    func splitParagraph(
        _ info: ParagraphInfo,
        at caret: Int,
        lowerBlock: MarkdownBlock,
        lowerLists: [NSTextList]? = nil,
        actionName: String
    ) -> Bool {
        let lists = lowerLists ?? info.lists
        let tailRange = NSRange(location: caret, length: NSMaxRange(info.range) - caret)
        let replacement = NSMutableAttributedString(attributedString: separator(block: info.block, textLists: info.lists))
        if tailRange.length > 0 {
            replacement.append(reblocked(textStorage.attributedSubstring(from: tailRange), block: lowerBlock, textLists: lists))
        } else if lists.contains(where: { !$0.markerFormat.rawValue.isEmpty }) {
            replacement.append(separator(block: lowerBlock, textLists: lists))
        }
        let applied = replace(
            tailRange,
            with: replacement,
            actionName: actionName,
            selection: NSRange(location: caret + 1, length: 0)
        )
        if applied, caret == NSMaxRange(info.content) {
            applyTypingAttributes(typingAttributes(for: lowerBlock, textLists: lists))
        }
        return applied
    }

    private func handleCodeNewline(_ info: ParagraphInfo, caret: Int) -> Bool {
        guard info.isEmpty, let group = info.block.codeGroup else { return false }
        let previous = previousParagraphInfo(before: info)
        let next = nextParagraphInfo(after: info)
        let isLast = info.isTrailingEmpty || next?.block.codeGroup != group
        let hasEarlierLine = previous?.block.codeGroup == group
        guard isLast, hasEarlierLine else { return false }
        return setBlock(info.block.with(leaf: .paragraph), for: info, actionName: "Exit Code Block")
    }

    private func applyFenceRule(_ info: ParagraphInfo, caret: Int) -> Bool? {
        guard !info.block.isCode, info.block.leaf == .paragraph, !info.isTrailingEmpty,
              caret == NSMaxRange(info.content) else { return nil }
        let text = (textStorage.string as NSString).substring(with: info.content)
        guard let language = Self.fenceInfo(text), !containsSpecialCharacters(info.content) else { return nil }
        let block = info.block.with(leaf: .code(language: language.isEmpty ? nil : language, group: .mint())).with(task: nil)
        let codeAttributes = paragraphAttributes(for: block, textLists: info.lists)
        let replacement = NSMutableAttributedString(string: "\n", attributes: codeAttributes)
        let target = info.hasSeparator ? info.range : info.content
        let applied = replace(target, with: replacement, actionName: "Code Block", selection: NSRange(location: info.range.location, length: 0))
        if applied, !info.hasSeparator {
            applyTypingAttributes(typingAttributes(for: block, textLists: info.lists))
        }
        return applied
    }

    static func fenceInfo(_ text: String) -> String? {
        for fence in ["```", "~~~"] where text.hasPrefix(fence) {
            let rest = text.drop(while: { $0 == fence.first })
            guard text.count - rest.count >= 3 else { return nil }
            let info = rest.trimmingCharacters(in: .whitespaces)
            if fence == "```", info.contains("`") { return nil }
            return info
        }
        return nil
    }

    private func applyThematicBreakRule(_ info: ParagraphInfo, caret: Int) -> Bool? {
        guard !info.block.isCode, info.block.leaf == .paragraph, !info.isTrailingEmpty,
              caret == NSMaxRange(info.content), !info.block.isListItemStart else { return nil }
        let text = (textStorage.string as NSString).substring(with: info.content)
        guard ["---", "***", "___"].contains(text), !containsSpecialCharacters(info.content) else { return nil }
        let rule = makeRuleAttachment(source: text)
        let atomBlock = MarkdownBlock(leaf: .thematicBreak, containers: info.block.containers, isContinuation: info.block.isContinuation)
        let lowerBlock = MarkdownBlock(containers: info.block.containers, isContinuation: info.block.isListItem)
        let replacement = NSMutableAttributedString(attachment: rule)
        replacement.addAttributes(paragraphAttributes(for: atomBlock, textLists: info.lists), range: NSRange(location: 0, length: 1))
        replacement.append(separator(block: atomBlock, textLists: info.lists))
        if info.hasSeparator {
            replacement.append(separator(block: lowerBlock, textLists: info.lists))
        }
        let applied = replace(info.range, with: replacement, actionName: "Horizontal Rule", selection: NSRange(location: info.range.location + 2, length: 0))
        if applied, !info.hasSeparator {
            applyTrailingBlock(lowerBlock, textLists: info.lists, actionName: "Horizontal Rule")
        }
        return applied
    }

    func containsSpecialCharacters(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var found = false
        textStorage.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.markdownLiteral] != nil || attributes[.attachment] != nil
                || !attributes.markdownInlineIntent.intersection(.markdownMarks).isEmpty
                || attributes[.link] != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func removeInnermostQuote(_ info: ParagraphInfo, actionName: String) -> Bool {
        var containers = info.block.containers
        guard let index = containers.lastIndex(where: Self.isQuote) else { return false }
        containers.remove(at: index)
        return setBlock(info.block.with(containers: containers), for: info, actionName: actionName)
    }

    private func insertParagraphBesideAtom(_ info: ParagraphInfo, caret: Int, text: String) -> Bool {
        let plain = MarkdownBlock(containers: info.block.containers, isContinuation: info.block.isListItem)
        let textAttributes = paragraphAttributes(for: plain, textLists: info.lists)
        let length = (text as NSString).length
        if caret == info.content.location {
            let replacement = NSMutableAttributedString(string: text + "\n", attributes: textAttributes)
            return replace(
                NSRange(location: caret, length: 0),
                with: replacement,
                actionName: text.isEmpty ? "New Paragraph" : "Typing",
                selection: NSRange(location: caret + length + (text.isEmpty ? 1 : 0), length: 0)
            )
        }
        let tail = NSRange(location: caret, length: NSMaxRange(info.range) - caret)
        let replacement = NSMutableAttributedString(attributedString: separator(block: info.block, textLists: info.lists))
        replacement.append(NSAttributedString(string: text, attributes: textAttributes))
        if info.hasSeparator {
            replacement.append(NSAttributedString(string: "\n", attributes: textAttributes))
        }
        let applied = replace(
            tail,
            with: replacement,
            actionName: text.isEmpty ? "New Paragraph" : "Typing",
            selection: NSRange(location: caret + 1 + length, length: 0)
        )
        if applied, !info.hasSeparator, text.isEmpty {
            applyTrailingBlock(plain, textLists: info.lists, actionName: "New Paragraph")
        }
        return applied
    }

    private func deleteAtomParagraph(_ info: ParagraphInfo) -> Bool {
        if info.hasSeparator {
            return replace(info.range, with: NSAttributedString(), actionName: "Delete", selection: NSRange(location: info.range.location, length: 0))
        }
        if info.range.location > 0 {
            let target = NSRange(location: info.range.location - 1, length: info.range.length + 1)
            return replace(target, with: NSAttributedString(), actionName: "Delete", selection: NSRange(location: target.location, length: 0))
        }
        let applied = replace(info.range, with: NSAttributedString(), actionName: "Delete", selection: NSRange(location: 0, length: 0))
        if applied {
            applyTrailingBlock(MarkdownBlock(containers: info.block.containers), textLists: [], actionName: "Delete")
        }
        return applied
    }

    private func handleListNewline(_ info: ParagraphInfo, caret: Int) -> Bool? {
        guard !usesNativeListEditing else { return nil }
        if info.isEmpty, info.block.isListItemStart {
            return outdentList([info], actionName: "Outdent")
        }
        let lower = info.block.with(isContinuation: false).with(task: info.block.task == nil ? nil : .unchecked)
        return splitParagraph(info, at: caret, lowerBlock: lower, actionName: "New Item")
    }

    func indentList(_ selected: [ParagraphInfo], actionName: String) -> Bool {
        guard let head = selected.first else { return false }
        let paragraphs = expandedToWholeItems(selected, atDepth: effectiveLists(head).count)
        guard let first = paragraphs.first else { return false }
        let base = effectiveLists(first)
        guard let innermost = base.last else { return false }
        let depth = base.count
        guard let previous = previousParagraphInfo(before: first) else { return true }
        let previousLists = effectiveLists(previous)
        guard previousLists.count >= depth, zip(previousLists, base).allSatisfy({ $0 === $1 }) else { return true }
        let list = previousLists.count > depth
            ? previousLists[depth]
            : LoaderStructure.makeList(ordered: innermost.hasOrderedMarker, start: 1, depth: depth + 1)
        let applied = rewriteParagraphs(paragraphs, actionName: actionName) { info in
            let effective = self.effectiveLists(info)
            guard effective.count >= depth, zip(effective, base).allSatisfy({ $0 === $1 }) else { return nil }
            var lists = info.lists
            let rawIndex = lists.firstIndex(where: { $0 === base[depth - 1] }).map { $0 + 1 } ?? lists.count
            lists.insert(list, at: rawIndex)
            var containers = info.block.containers
            containers.insert(.listItem, at: Self.containerIndex(afterListItem: depth, in: containers))
            let isContinuation = info.range.location == first.range.location ? false : info.block.isContinuation
            let block = MarkdownBlock(leaf: info.block.leaf, containers: containers, isContinuation: isContinuation, task: info.block.task)
            return (block, lists)
        }
        _ = applied
        return true
    }

    func outdentList(_ selected: [ParagraphInfo], actionName: String) -> Bool {
        guard let head = selected.first else { return false }
        let paragraphs = expandedToWholeItems(selected, atDepth: effectiveLists(head).count)
        guard let first = paragraphs.first else { return false }
        let base = effectiveLists(first)
        guard let removed = base.last else { return false }
        let depth = base.count
        return rewriteParagraphs(paragraphs, actionName: actionName) { info in
            let effective = self.effectiveLists(info)
            guard effective.count >= depth, zip(effective, base).allSatisfy({ $0 === $1 }) else { return nil }
            var lists = info.lists
            lists.removeAll { $0 === removed }
            var containers = info.block.containers
            let index = Self.containerIndex(afterListItem: depth, in: containers) - 1
            if index >= 0, index < containers.count, containers[index] == .listItem {
                containers.remove(at: index)
            }
            let stillList = containers.contains(.listItem)
            let block = MarkdownBlock(
                leaf: info.block.leaf,
                containers: containers,
                isContinuation: stillList ? info.block.isContinuation : false,
                task: stillList ? info.block.task : nil
            )
            return (block, lists)
        }
    }

    static func containerIndex(afterListItem count: Int, in containers: [MarkdownBlock.Container]) -> Int {
        var seen = 0
        for (index, container) in containers.enumerated() where container == .listItem {
            seen += 1
            if seen == count { return index + 1 }
        }
        return containers.count
    }

    func effectiveLists(_ info: ParagraphInfo) -> [NSTextList] {
        info.lists.filter { !$0.markerFormat.rawValue.isEmpty }
    }

    func expandedToWholeItems(_ paragraphs: [ParagraphInfo], atDepth depth: Int) -> [ParagraphInfo] {
        guard depth > 0, var head = paragraphs.first, var tail = paragraphs.last else { return paragraphs }
        var result = paragraphs
        func continuesItem(_ info: ParagraphInfo, in list: NSTextList) -> Bool {
            let lists = effectiveLists(info)
            return lists.count >= depth && lists[depth - 1] === list
                && (lists.count > depth || info.block.isContinuation)
        }
        while let list = effectiveLists(head).dropFirst(depth - 1).first, continuesItem(head, in: list),
              let previous = previousParagraphInfo(before: head) {
            let lists = effectiveLists(previous)
            guard lists.count >= depth, lists[depth - 1] === list else { break }
            result.insert(previous, at: 0)
            head = previous
        }
        while let list = effectiveLists(tail).dropFirst(depth - 1).first,
              let next = nextParagraphInfo(after: tail), continuesItem(next, in: list) {
            result.append(next)
            tail = next
        }
        return result
    }

    func rewriteParagraphs(
        _ paragraphs: [ParagraphInfo],
        actionName: String,
        _ transform: (ParagraphInfo) -> (MarkdownBlock, [NSTextList])?
    ) -> Bool {
        var changes: [(ParagraphInfo, MarkdownBlock, [NSTextList])] = []
        for info in paragraphs {
            guard let (block, lists) = transform(info) else { continue }
            changes.append((info, block, lists))
        }
        guard !changes.isEmpty else { return false }
        if changes.count == 1, let (info, block, lists) = changes.first, info.isTrailingEmpty {
            return applyTrailingBlock(block, textLists: lists, actionName: actionName)
        }
        let stored = changes.filter { !$0.0.isTrailingEmpty }
        guard let first = stored.first, let last = stored.last else { return false }
        let union = NSUnionRange(first.0.range, last.0.range)
        let styles = stored.map { restyler.paragraphStyle(for: $0.1, textLists: $0.2) }
        let applied = editAttributes(in: union, actionName: actionName) { storage in
            for (index, change) in stored.enumerated() {
                storage.addAttribute(.markdownBlock, value: change.1, range: change.0.range)
                storage.addAttribute(.paragraphStyle, value: styles[index], range: change.0.range)
            }
        }
        if applied, let trailing = changes.last, trailing.0.isTrailingEmpty {
            let selection = currentSelection
            applyTrailingBlock(trailing.1, textLists: trailing.2, actionName: actionName)
            setSelection(selection)
        }
        return applied
    }
}
