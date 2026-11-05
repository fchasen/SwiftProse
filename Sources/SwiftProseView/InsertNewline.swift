import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum InsertNewline {

    @discardableResult
    public static func handle(
        in storage: NSTextStorage,
        cursor: Int,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange? {
        handle(
            in: storage,
            selection: NSRange(location: cursor, length: 0),
            compiler: compiler,
            serializer: serializer,
            theme: theme
        )
    }

    /// Return inside a list item. An empty item leaves the list. Otherwise
    /// the text after the caret moves into a new item below it; with the
    /// caret before the item's first character that is all of it, so an
    /// empty item opens above and the caret stays with the text. Selected
    /// text inside the item is deleted first.
    @discardableResult
    public static func handle(
        in storage: NSTextStorage,
        selection: NSRange,
        compiler: MarkdownAttributedCompiler,
        serializer: AttributedMarkdownSerializer,
        theme: ProseTheme
    ) -> NSRange? {
        let ns = storage.string as NSString
        let cursor = selection.location
        guard cursor >= 0, cursor <= ns.length, ns.length > 0 else { return nil }
        let probe = max(0, min(cursor, ns.length - 1))
        guard let spec = storage.blockSpec(at: probe), spec.isListItem else {
            return nil
        }
        let kind: ListItemKind
        let orderedIndex: Int?
        switch spec.kind {
        case .unorderedListItem:
            kind = .bullet; orderedIndex = nil
        case .orderedListItem(let i):
            kind = .ordered; orderedIndex = i
        case .taskListItem:
            kind = .task; orderedIndex = nil
        default:
            return nil
        }
        let newChecked: Bool? = kind == .task ? false : nil
        var lineRange = ns.paragraphRange(for: NSRange(location: probe, length: 0))

        if isEmptyListLine(in: storage, lineRange: lineRange) {
            let plainAttrs = theme.plainParagraphAttributes()
            let replacement = NSAttributedString(string: "\n", attributes: plainAttrs)
            storage.beginEditing()
            storage.replaceCharacters(in: lineRange, with: replacement)
            Step.restampPredecessorContext(in: storage, range: lineRange)
            storage.endEditing()
            return NSRange(location: lineRange.location, length: 0)
        }

        let bodyStart = bodyStart(in: storage, lineRange: lineRange)
        storage.beginEditing()
        defer { storage.endEditing() }

        if ns.character(at: NSMaxRange(lineRange) - 1) != 0x0A {
            let attrs = storage.attributes(at: NSMaxRange(lineRange) - 1, effectiveRange: nil)
            storage.replaceCharacters(
                in: NSRange(location: NSMaxRange(lineRange), length: 0),
                with: NSAttributedString(string: "\n", attributes: attrs)
            )
            lineRange.length += 1
        }
        var lineEnd = NSMaxRange(lineRange) - 1
        var caret = cursor
        let body = NSRange(location: bodyStart, length: max(0, lineEnd - bodyStart))
        let selected = NSIntersectionRange(selection, body)
        if selection.length > 0, selected.length > 0 {
            storage.replaceCharacters(in: selected, with: "")
            lineRange.length -= selected.length
            lineEnd -= selected.length
            caret = selected.location
        }
        caret = max(bodyStart, min(caret, lineEnd))

        if caret == bodyStart {
            let item = compiler.makeListItem(
                kind: kind,
                level: spec.listLevel,
                orderedIndex: orderedIndex,
                isChecked: newChecked,
                theme: theme
            )
            storage.replaceCharacters(in: NSRange(location: lineRange.location, length: 0), with: item)
            let itemRange = NSRange(location: lineRange.location, length: item.length)
            if let itemSpec = item.blockSpec(at: 0),
               let below = storage.nodePath(at: NSMaxRange(itemRange)) {
                storage.setNodePath(NodePath.fromBlockSpec(itemSpec, predecessor: below), in: itemRange)
            }
            return NSRange(location: bodyStart + item.length, length: 0)
        }

        let item = NSMutableAttributedString(attributedString: compiler.makeListItem(
            kind: kind,
            level: spec.listLevel,
            orderedIndex: orderedIndex.map { $0 + 1 },
            isChecked: newChecked,
            theme: theme
        ))
        let markerLength = item.length - 1
        let tailRange = NSRange(location: caret, length: lineEnd - caret)
        if tailRange.length > 0 {
            let tail = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: tailRange))
            let whole = NSRange(location: 0, length: tail.length)
            if let box = item.attribute(.proseNodePath, at: 0, effectiveRange: nil) as? NodePathBox {
                tail.enumerateAttribute(.proseNodePath, in: whole) { value, run, _ in
                    if let old = value as? NodePathBox, InlineLeafRuns.isLiftable(old.path.leaf) { return }
                    tail.addAttribute(.proseNodePath, value: box, range: run)
                }
            }
            if let style = item.attribute(.paragraphStyle, at: 0, effectiveRange: nil) {
                tail.addAttribute(.paragraphStyle, value: style, range: whole)
            }
            item.insert(tail, at: markerLength)
            storage.replaceCharacters(in: tailRange, with: "")
        }
        let insertLocation = NSMaxRange(lineRange) - tailRange.length
        storage.replaceCharacters(in: NSRange(location: insertLocation, length: 0), with: item)
        let itemRange = NSRange(location: insertLocation, length: item.length)
        Step.restampPredecessorContext(in: storage, range: itemRange)
        Step.unifyLineNodePaths(in: storage, range: itemRange)
        return NSRange(location: insertLocation + markerLength, length: 0)
    }

    /// First offset after the marker run (FFFC or `"1. "`, plus its space).
    private static func bodyStart(in storage: NSTextStorage, lineRange: NSRange) -> Int {
        var markerRange = NSRange(location: lineRange.location, length: 0)
        if let flag = storage.safeAttribute(.proseListMarker, at: lineRange.location, longestEffectiveRange: &markerRange, in: lineRange) as? Bool, flag {
            return NSMaxRange(markerRange)
        }
        return lineRange.location
    }

    /// True if `lineRange` contains only the marker run plus a trailing
    /// newline — the user has not typed any body content for this item.
    private static func isEmptyListLine(in storage: NSTextStorage, lineRange: NSRange) -> Bool {
        guard lineRange.length > 0,
              lineRange.location + lineRange.length <= storage.length,
              lineRange.location < storage.length else {
            return true
        }
        let start = bodyStart(in: storage, lineRange: lineRange)
        let bodyEnd = lineRange.location + lineRange.length
        guard bodyEnd > start else { return true }
        let body = (storage.string as NSString).substring(with: NSRange(location: start, length: bodyEnd - start))
        let trimmed = body.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
    }
}
