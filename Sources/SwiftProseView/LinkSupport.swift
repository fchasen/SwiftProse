import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension EditorController {
    /// Look up the link mark covering `position`. Walks `proseMarks`
    /// outward to find the contiguous span. Returns nil if `position`
    /// isn't inside a link.
    public func linkMark(at position: Int) -> (range: NSRange, href: String, title: String)? {
        let storage = textStorage
        let len = storage.length
        guard position >= 0, position < len else { return nil }
        // Pick a probe point inside the run. Reading at `position` itself
        // is fine; if `position` happens to be at the boundary of the
        // link, walk-outward below extends the range to the full span.
        guard let initialMarks = storage.markSet(at: position),
              let initial = initialMarks.mark(of: "link") else { return nil }
        let href = initial.attrs["href"]?.stringValue ?? ""
        let title = initial.attrs["title"]?.stringValue ?? ""
        var start = position
        while start > 0,
              let marks = storage.markSet(at: start - 1),
              let mark = marks.mark(of: "link"),
              mark.attrs["href"]?.stringValue == href {
            start -= 1
        }
        var end = position
        while end < len,
              let marks = storage.markSet(at: end),
              let mark = marks.mark(of: "link"),
              mark.attrs["href"]?.stringValue == href {
            end += 1
        }
        return (NSRange(location: start, length: end - start), href, title)
    }

    /// Replace the link mark's `href` / `title` over `range` in place.
    /// Caller usually passes the result of `linkMark(at:)`'s `range`.
    /// The transaction is undoable as one unit.
    public func updateLink(in range: NSRange, href: String, title: String = "") -> Transaction {
        var attrs: [String: ProseAttrValue] = ["href": .string(href)]
        if !title.isEmpty {
            attrs["title"] = .string(title)
        }
        return Transaction(
            steps: [.setMarkAttrs(range: range, markName: "link", attrs: attrs)],
            label: "Edit Link"
        )
    }

    /// Strip the link mark from `range` while leaving the underlying text
    /// intact.
    public func removeLink(in range: NSRange) -> Transaction {
        Transaction(
            steps: [.removeMark(range: range, markType: "link")],
            label: "Remove Link"
        )
    }
}
