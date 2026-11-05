import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension EditorController {
    func recordTypedInput(range: NSRange, replacement: String?) {
        guard let replacement, replacement.count == 1, !hostHasMarkedText, !isSettingMarkedText,
              let character = replacement.first, InputRules.triggers.contains(character) else {
            pendingInput = nil
            return
        }
        pendingInput = TypedInput(location: range.location, text: replacement)
    }

    func scheduleInputRules() {
        guard let input = pendingInput else { return }
        pendingInput = nil
        guard !isWritingToolsActive else { return }
        deferEdit { [weak self] in
            self?.applyInputRules(after: input)
        }
    }

    @discardableResult
    func applyInputRules(after input: TypedInput) -> Bool {
        guard canApplyKeyRules, !isWritingToolsActive else { return false }
        let caret = input.caret
        guard currentSelection == NSRange(location: caret, length: 0), caret <= textStorage.length, caret > 0 else { return false }
        let ns = textStorage.string as NSString
        guard ns.substring(with: NSRange(location: input.location, length: (input.text as NSString).length)) == input.text else {
            return false
        }
        let info = paragraphInfo(at: caret)
        guard !info.block.isCode, !info.block.isAtom, caret <= NSMaxRange(info.content) else { return false }
        if input.text == " ", applyBlockRule(info, caret: caret) { return true }
        return applyInlineCloser(info, caret: caret, typed: input.text)
    }

    private func applyBlockRule(_ info: ParagraphInfo, caret: Int) -> Bool {
        guard !info.block.isTableRow else { return false }
        let prefixRange = NSRange(location: info.content.location, length: caret - info.content.location)
        guard prefixRange.length >= 2, prefixRange.length <= 12, !containsSpecialCharacters(prefixRange) else { return false }
        let prefix = (textStorage.string as NSString).substring(with: prefixRange)
        guard let rule = InputRules.blockRule(for: prefix) else { return false }
        let block = info.block
        var lists = info.lists
        let newBlock: MarkdownBlock
        let actionName: String
        switch rule {
        case .heading(let level):
            guard block.leaf == .paragraph || block.headingLevel != nil else { return false }
            newBlock = block.with(leaf: .heading(level: level))
            actionName = "Heading"
        case .bullet, .ordered:
            guard block.leaf == .paragraph, !block.isListItemStart || effectiveLists(info).isEmpty else { return false }
            let ordered: Bool
            let start: Int
            if case .ordered(let number) = rule {
                ordered = true
                start = number
            } else {
                ordered = false
                start = 1
            }
            let list = listForNewItem(info, ordered: ordered, start: start)
            lists = info.lists + [list]
            newBlock = MarkdownBlock(leaf: .paragraph, containers: block.containers + [.listItem])
            actionName = ordered ? "Numbered List" : "Bulleted List"
        case .quote:
            guard block.leaf == .paragraph else { return false }
            let token = quoteTokenForNewQuote(info)
            newBlock = block.with(containers: block.containers + [.quote(token)]).with(isContinuation: false).with(task: nil)
            actionName = "Quote"
        case .task(let checked):
            guard block.leaf == .paragraph, block.task == nil else { return false }
            if block.isListItemStart {
                newBlock = block.with(task: TaskState(checked: checked))
            } else {
                let list = listForNewItem(info, ordered: false, start: 1)
                lists = info.lists + [list]
                newBlock = MarkdownBlock(leaf: .paragraph, containers: block.containers + [.listItem], task: TaskState(checked: checked))
            }
            actionName = "Task"
        }
        let rest = NSRange(location: caret, length: NSMaxRange(info.range) - caret)
        let replacement = reblocked(textStorage.attributedSubstring(from: rest), block: newBlock, textLists: lists)
        if replacement.length == 0, lists.contains(where: { !$0.markerFormat.rawValue.isEmpty }) {
            replacement.append(separator(block: newBlock, textLists: lists))
        }
        let applied = replace(
            NSRange(location: info.range.location, length: info.range.length),
            with: replacement,
            actionName: actionName,
            selection: NSRange(location: info.range.location, length: 0)
        )
        if applied {
            applyTypingAttributes(typingAttributes(for: newBlock, textLists: lists))
        }
        return applied
    }

    func listForNewItem(_ info: ParagraphInfo, ordered: Bool, start: Int) -> NSTextList {
        let depth = effectiveLists(info).count
        if let previous = previousParagraphInfo(before: info) {
            let previousLists = effectiveLists(previous)
            let current = effectiveLists(info)
            if previousLists.count > depth, zip(previousLists, current).allSatisfy({ $0 === $1 }),
               previousLists[depth].hasOrderedMarker == ordered {
                return previousLists[depth]
            }
        }
        return LoaderStructure.makeList(ordered: ordered, start: start, depth: depth + 1)
    }

    private func quoteTokenForNewQuote(_ info: ParagraphInfo) -> GroupToken {
        if let previous = previousParagraphInfo(before: info),
           previous.block.containers.count == info.block.containers.count + 1,
           Array(previous.block.containers.prefix(info.block.containers.count)) == info.block.containers,
           case .quote(let token) = previous.block.containers.last {
            return token
        }
        return .mint()
    }

    private func applyInlineCloser(_ info: ParagraphInfo, caret: Int, typed: String) -> Bool {
        guard let delimiterCharacter = typed.first, InputRules.closers.contains(delimiterCharacter) else { return false }
        let lineRange = NSRange(location: info.content.location, length: caret - info.content.location)
        guard lineRange.length >= 3 else { return false }
        let line = (textStorage.string as NSString).substring(with: lineRange)
        guard let match = InputRules.closerMatch(in: line, typed: delimiterCharacter) else { return false }
        let opener = NSRange(location: lineRange.location + match.opener.location, length: match.opener.length)
        let content = NSRange(location: lineRange.location + match.content.location, length: match.content.length)
        let whole = NSRange(location: opener.location, length: caret - opener.location)
        guard !spanBlocksCloser(whole) else { return false }
        let styled = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: content))
        let full = NSRange(location: 0, length: styled.length)
        styled.enumerateAttribute(.markdownInlineIntent, in: full) { value, run, _ in
            var intent = MarkdownInlineIntent(attributeValue: value) ?? []
            intent.insert(match.mark)
            styled.addAttribute(.markdownInlineIntent, value: intent.attributeValue, range: run)
        }
        if match.mark == .code {
            styled.removeAttribute(.markdownLiteral, range: full)
        }
        let end = opener.location + styled.length
        let applied = replace(whole, with: styled, actionName: InputRules.actionName(for: match.mark), selection: NSRange(location: end, length: 0))
        if applied {
            let intent = typingAttributes(at: end).markdownInlineIntent.subtracting(match.mark)
            applyTypingAttributes(typingAttributes(for: info.block, textLists: info.lists, intent: intent))
        }
        return applied
    }

    private func spanBlocksCloser(_ range: NSRange) -> Bool {
        var blocked = false
        let ns = textStorage.string as NSString
        textStorage.enumerateAttributes(in: range) { attributes, run, stop in
            if attributes[.attachment] != nil || attributes.markdownInlineIntent.contains(.code)
                || attributes[.markdownLiteral] != nil {
                let text = ns.substring(with: run)
                if attributes[.markdownLiteral] != nil, !text.contains(where: { InputRules.closers.contains($0) }) {
                    return
                }
                blocked = true
                stop.pointee = true
            }
        }
        if !blocked {
            for index in range.location..<NSMaxRange(range) where ns.character(at: index) == MarkdownBreak.utf16 {
                blocked = true
                break
            }
        }
        return blocked
    }
}

enum InputRules {
    enum BlockRule: Equatable {
        case heading(Int)
        case bullet
        case ordered(Int)
        case quote
        case task(checked: Bool)
    }

    struct CloserMatch {
        var opener: NSRange
        var content: NSRange
        var mark: MarkdownInlineIntent
    }

    static let closers: Set<Character> = ["*", "_", "~", "`"]
    static let triggers: Set<Character> = closers.union([" "])

    static func blockRule(for prefix: String) -> BlockRule? {
        guard prefix.hasSuffix(" ") else { return nil }
        let marker = String(prefix.dropLast())
        if !marker.isEmpty, marker.count <= 6, marker.allSatisfy({ $0 == "#" }) {
            return .heading(marker.count)
        }
        switch marker {
        case "-", "*", "+": return .bullet
        case ">": return .quote
        case "[ ]", "[]": return .task(checked: false)
        case "[x]", "[X]": return .task(checked: true)
        default: break
        }
        if let last = marker.last, last == "." || last == ")" {
            let digits = marker.dropLast()
            if !digits.isEmpty, digits.count <= 9, digits.allSatisfy(\.isASCIIDigit), let number = Int(digits) {
                return .ordered(number)
            }
        }
        return nil
    }

    static func actionName(for mark: MarkdownInlineIntent) -> String {
        switch mark {
        case .stronglyEmphasized: return "Bold"
        case .emphasized: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code: return "Code"
        default: return "Format"
        }
    }

    static func closerMatch(in line: String, typed: Character) -> CloserMatch? {
        let units = Array(line.utf16)
        let count = units.count
        guard count >= 3, let typedUnit = String(typed).utf16.first, units[count - 1] == typedUnit else { return nil }

        func isWhitespace(_ unit: UInt16) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0xA0
        }
        func isAlphanumeric(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return true }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        func match(delimiter: [UInt16], mark: MarkdownInlineIntent, allowSpaces: Bool, intraword: Bool) -> CloserMatch? {
            let width = delimiter.count
            guard count >= width * 2 + 1, Array(units[(count - width)...]) == delimiter else { return nil }
            let closerStart = count - width
            if width == 1, closerStart > 0, units[closerStart - 1] == delimiter[0] { return nil }
            guard closerStart >= 1 else { return nil }
            if !allowSpaces, isWhitespace(units[closerStart - 1]) { return nil }
            var openerStart = closerStart - width
            while openerStart >= 0 {
                if Array(units[openerStart..<(openerStart + width)]) == delimiter {
                    let contentStart = openerStart + width
                    let contentLength = closerStart - contentStart
                    let precededByDelimiter = openerStart > 0 && units[openerStart - 1] == delimiter[0]
                    let followedByDelimiter = width == 1 && contentStart < closerStart && units[contentStart] == delimiter[0]
                    if contentLength > 0, !precededByDelimiter, !followedByDelimiter {
                        if !allowSpaces, isWhitespace(units[contentStart]) { return nil }
                        if !intraword, openerStart > 0, isAlphanumeric(units[openerStart - 1]) { return nil }
                        return CloserMatch(
                            opener: NSRange(location: openerStart, length: width),
                            content: NSRange(location: contentStart, length: contentLength),
                            mark: mark
                        )
                    }
                    if contentLength == 0 { return nil }
                }
                openerStart -= 1
            }
            return nil
        }

        switch typed {
        case "*":
            return match(delimiter: [0x2A, 0x2A], mark: .stronglyEmphasized, allowSpaces: false, intraword: true)
                ?? match(delimiter: [0x2A], mark: .emphasized, allowSpaces: false, intraword: true)
        case "_":
            return match(delimiter: [0x5F, 0x5F], mark: .stronglyEmphasized, allowSpaces: false, intraword: false)
                ?? match(delimiter: [0x5F], mark: .emphasized, allowSpaces: false, intraword: false)
        case "~":
            return match(delimiter: [0x7E, 0x7E], mark: .strikethrough, allowSpaces: false, intraword: true)
        case "`":
            return match(delimiter: [0x60], mark: .code, allowSpaces: true, intraword: true)
        default:
            return nil
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
