import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public protocol ProseEditing: AnyObject {
    var textStorage: NSTextStorage { get }
    var currentSelection: NSRange { get }
    var hostTextView: PlatformTextView? { get }
    var isEditable: Bool { get }

    func setSelection(_ range: NSRange)
    func markdown() -> String
    func caretRect() -> CGRect?
    func rect(forCharacterAt index: Int) -> CGRect?

    @discardableResult
    func insertMarkdown(_ markdown: String, replacing range: NSRange, label: String) -> Bool
    @discardableResult
    func replaceText(in range: NSRange, with text: String, label: String) -> Bool
    @discardableResult
    func insertLink(label: String, url: String) -> Bool
    @discardableResult
    func insertInlineContent(
        _ content: ProseInlineContent,
        markdownSource: String,
        replacing range: NSRange,
        trailingText: String,
        label: String
    ) -> Bool
    @discardableResult
    func insertMarkdownAtLineStart(_ markdown: String, replacingLeading rule: InlineContentRule?, label: String) -> Bool

    func pluginState<State>(for key: PluginKey<State>) -> State?
    func setPluginState<State>(_ state: State, for key: PluginKey<State>)
    func clearPluginState<State>(for key: PluginKey<State>)
}

public extension ProseEditing {
    @discardableResult
    func insertMarkdown(_ markdown: String, label: String = "Insert") -> Bool {
        insertMarkdown(markdown, replacing: currentSelection, label: label)
    }

    @discardableResult
    func replaceText(in range: NSRange, with text: String) -> Bool {
        replaceText(in: range, with: text, label: "Replace")
    }

    @discardableResult
    func insertInlineContent(_ content: ProseInlineContent, markdownSource: String, replacing range: NSRange) -> Bool {
        insertInlineContent(content, markdownSource: markdownSource, replacing: range, trailingText: " ", label: "Insert")
    }

    @discardableResult
    func insertMarkdownAtLineStart(_ markdown: String, replacingLeading rule: InlineContentRule? = nil) -> Bool {
        insertMarkdownAtLineStart(markdown, replacingLeading: rule, label: "Insert")
    }
}

protocol CompletionSupporting: ProseEditing {
    var isComposingText: Bool { get }
    var isApplyingCommand: Bool { get }
    var hasPendingDocumentChange: Bool { get }
    func deferEdit(_ work: @escaping () -> Void)
    func allowsCompletionTrigger(at location: Int, replacing range: NSRange, allowedInCode: Bool) -> Bool
}

extension InlineContentRule {
    func matchesEntirely(_ text: String) -> Bool {
        let length = (text as NSString).length
        guard let match = regex.firstMatch(in: text, options: .anchored, range: NSRange(location: 0, length: length)) else {
            return false
        }
        return match.range.length == length
    }

    func leadingMatch(in text: NSString, at location: Int, limit: Int) -> NSRange? {
        let range = NSRange(location: location, length: max(0, limit - location))
        guard let match = regex.firstMatch(in: text as String, options: .anchored, range: range), match.range.length > 0 else {
            return nil
        }
        var end = NSMaxRange(match.range)
        while end < limit, SourceDocument.isSpace(text.character(at: end)) { end += 1 }
        return NSRange(location: location, length: end - location)
    }
}

extension EditorController: CompletionSupporting {
    var isComposingText: Bool { hostHasMarkedText || isSettingMarkedText }

    @discardableResult
    public func insertMarkdownAtLineStart(_ markdown: String, replacingLeading rule: InlineContentRule?, label: String = "Insert") -> Bool {
        guard isEditable else { return false }
        let ns = textStorage.string as NSString
        let caret = min(currentSelection.location, ns.length)
        let info = paragraphInfo(at: caret)
        let start = info.content.location
        var target = NSRange(location: start, length: 0)
        if let rule, start < ns.length {
            if let atom = textStorage.proseSourceAttachment(at: start), rule.matchesEntirely(atom.markdownSource) {
                var length = 1
                while start + length < NSMaxRange(info.content), SourceDocument.isSpace(ns.character(at: start + length)) { length += 1 }
                target.length = length
            } else if let match = rule.leadingMatch(in: ns, at: start, limit: NSMaxRange(info.content)) {
                target = match
            }
        }
        setSelection(target)
        return insertMarkdown(markdown, replacing: target, label: label)
    }

    func allowsCompletionTrigger(at location: Int, replacing range: NSRange, allowedInCode: Bool) -> Bool {
        guard !allowedInCode else { return true }
        let ns = textStorage.string as NSString
        let info = paragraphInfo(at: location)
        if info.block.isCode || info.block.isAtom { return false }
        if isLocationInCode(location) { return false }
        if range.length == 0, location > 0, location < ns.length,
           textStorage.markdownInlineIntent(at: location - 1).contains(.code),
           hostTypingAttributes.markdownInlineIntent.contains(.code) {
            return false
        }
        return true
    }
}
