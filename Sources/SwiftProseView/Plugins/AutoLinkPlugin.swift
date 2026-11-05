import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public final class AutoLinkPlugin: EditorPlugin {
    public static let keyName = "swiftprose.autoLink"
    public static let actionName = "Auto Link"
    public let key = AnyPluginKey(name: keyName)
    public let rules: [AutoLinkRule]

    private var pendingRange: NSRange?
    private var pendingOrigin: DocumentChange.Origin = .user
    private var isApplying = false

    public init(rules: [AutoLinkRule]) {
        self.rules = rules
    }

    public func documentDidChange(_ change: DocumentChange, controller: EditorController) {
        guard !isApplying, !rules.isEmpty else { return }
        switch change.origin {
        case .undo, .load:
            pendingRange = nil
            return
        case .command where change.changeInLength == 0:
            return
        case .user, .command:
            break
        }
        let scheduled = pendingRange != nil
        if let pending = pendingRange {
            pendingRange = pending.merged(withEdit: change.editedRange, changeInLength: change.changeInLength)
            if change.origin == .command { pendingOrigin = .command }
        } else {
            pendingRange = change.editedRange
            pendingOrigin = change.origin
        }
        guard !scheduled else { return }
        controller.deferEdit { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.applyPending(controller: controller)
        }
    }

    func applyPending(controller: EditorController) {
        guard let edited = pendingRange else { return }
        let origin = pendingOrigin
        pendingRange = nil
        guard controller.isEditable,
              !controller.isWritingToolsActive,
              !controller.hostHasMarkedText,
              !controller.isSettingMarkedText else { return }
        let links = matches(around: edited, origin: origin, controller: controller)
        guard !links.isEmpty else { return }
        let union = links.dropFirst().reduce(links[0].range) { NSUnionRange($0, $1.range) }
        isApplying = true
        defer { isApplying = false }
        controller.editAttributes(in: union, actionName: Self.actionName) { storage in
            for link in links {
                storage.addAttribute(.link, value: URL(string: link.href).map { $0 as Any } ?? link.href, range: link.range)
            }
        }
    }

    struct PendingLink: Equatable {
        var range: NSRange
        var href: String
    }

    func matches(around edited: NSRange, origin: DocumentChange.Origin, controller: EditorController) -> [PendingLink] {
        let storage = controller.textStorage
        let total = storage.length
        guard total > 0 else { return [] }
        let start = max(0, min(edited.location, total) - 1)
        let end = min(total, max(start, NSMaxRange(edited)) + 1)
        let edit = Normalizer.clamp(edited, to: total)
        let selection = controller.currentSelection
        let caret: Int? = origin == .user && selection.length == 0 ? selection.location : nil
        var links: [PendingLink] = []
        let ns = storage.string as NSString
        for paragraph in storage.markdownParagraphRanges(in: NSRange(location: start, length: end - start)) {
            let hasSeparator = paragraph.length > 0 && ns.character(at: NSMaxRange(paragraph) - 1) == MarkdownParagraph.separator
            let content = NSRange(location: paragraph.location, length: paragraph.length - (hasSeparator ? 1 : 0))
            guard content.length > 0,
                  let block = storage.markdownBlock(at: content.location),
                  !block.isCode, !block.isAtom else { continue }
            let window = Self.searchWindow(around: edit, in: ns, within: content)
            let line = ns.substring(with: window)
            let search = NSRange(location: 0, length: window.length)
            for rule in rules {
                rule.pattern.enumerateMatches(in: line, options: [], range: search) { result, _, _ in
                    guard let result, result.numberOfRanges > rule.linkCapture else { return }
                    let relative = result.range(at: rule.linkCapture)
                    guard relative.location != NSNotFound, relative.length > 0 else { return }
                    let linkRange = NSRange(location: window.location + relative.location, length: relative.length)
                    let matchedRange = NSRange(location: window.location + result.range.location, length: result.range.length)
                    guard Self.touches(linkRange, edit) else { return }
                    if let caret {
                        let run = Self.nonWhitespaceRun(around: linkRange, in: ns, within: content)
                        if caret > run.location, caret <= NSMaxRange(run) { return }
                    }
                    if linkRange.location == matchedRange.location,
                       Self.isWordCharacter(before: linkRange.location, in: ns, floor: content.location) { return }
                    guard !Self.isExcluded(linkRange, in: storage) else { return }
                    guard !links.contains(where: { NSIntersectionRange($0.range, linkRange).length > 0 }) else { return }
                    let captures = (0..<result.numberOfRanges).map { index -> NSRange in
                        let capture = result.range(at: index)
                        guard capture.location != NSNotFound else { return capture }
                        return NSRange(location: window.location + capture.location, length: capture.length)
                    }
                    let match = AutoLinkMatch(
                        storage: storage,
                        matchedRange: matchedRange,
                        linkRange: linkRange,
                        captureRanges: captures
                    )
                    guard let href = rule.href(match), !href.isEmpty else { return }
                    links.append(PendingLink(range: linkRange, href: href))
                }
            }
        }
        return links.sorted { $0.range.location < $1.range.location }
    }

    static func touches(_ link: NSRange, _ edit: NSRange) -> Bool {
        edit.location <= NSMaxRange(link) + 1 && NSMaxRange(edit) >= link.location
    }

    static func searchWindow(around edit: NSRange, in ns: NSString, within content: NSRange) -> NSRange {
        let lower = max(content.location, min(edit.location, NSMaxRange(content)))
        let upper = max(lower, min(NSMaxRange(edit), NSMaxRange(content)))
        var start = nonWhitespaceRun(around: NSRange(location: lower, length: 0), in: ns, within: content).location
        while start > content.location, isWhitespace(ns.character(at: start - 1)) { start -= 1 }
        start = nonWhitespaceRun(around: NSRange(location: start, length: 0), in: ns, within: content).location
        start = max(content.location, start - 1)
        let end = min(NSMaxRange(content), NSMaxRange(nonWhitespaceRun(around: NSRange(location: upper, length: 0), in: ns, within: content)) + 1)
        return NSRange(location: start, length: end - start)
    }

    static func nonWhitespaceRun(around range: NSRange, in ns: NSString, within content: NSRange) -> NSRange {
        var start = range.location
        while start > content.location, !isWhitespace(ns.character(at: start - 1)) { start -= 1 }
        var end = NSMaxRange(range)
        while end < NSMaxRange(content), !isWhitespace(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func isWordCharacter(before location: Int, in ns: NSString, floor: Int) -> Bool {
        guard location > floor else { return false }
        let range = ns.rangeOfComposedCharacterSequence(at: location - 1)
        return ns.substring(with: range).unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    static func isExcluded(_ range: NSRange, in storage: NSAttributedString) -> Bool {
        var excluded = false
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[.link] != nil
                || attributes[.attachment] != nil
                || attributes.markdownInlineIntent.contains(.code) {
                excluded = true
                stop.pointee = true
            }
        }
        if excluded { return true }
        let ns = storage.string as NSString
        for index in range.location..<NSMaxRange(range) {
            let unit = ns.character(at: index)
            if unit == MarkdownParagraph.objectReplacement || unit == MarkdownBreak.utf16 { return true }
        }
        return false
    }
}
