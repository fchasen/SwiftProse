import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Resolves clicks on `[text](#anchor)` links to a position in the same
/// document. ProseMirror leaves anchor handling to the browser; in a native
/// text editor the OS would just hand `#anchor` to NSWorkspace / UIApplication
/// (no-op or error). This plugin intercepts the click before the OS sees it,
/// matches the fragment against a heading slug, and scrolls / selects.
///
/// External hrefs (`http://`, `mailto:`, etc.) and unresolved fragments fall
/// through to default OS handling.
public final class InternalLinkPlugin: EditorPlugin {
    public let key = AnyPluginKey(name: "internalLink")

    /// Slug strategy. Defaults to `.github` (lowercase, non-alnum → dash,
    /// collapse repeats, trim). Hosts that ship `{#explicit}` heading IDs
    /// can swap in `.exact` and pre-strip the heading body.
    public enum SlugStyle: Sendable {
        case github
        case exact
    }

    private let slugStyle: SlugStyle

    public init(slugStyle: SlugStyle = .github) {
        self.slugStyle = slugStyle
    }

    public var props: PluginProps {
        PluginProps(handleClick: { [weak self] controller, charIndex in
            self?.handleClick(controller: controller, at: charIndex) ?? false
        })
    }

    private func handleClick(controller: EditorController, at charIndex: Int) -> Bool {
        guard let href = linkHref(at: charIndex, in: controller.textStorage),
              let fragment = fragmentTarget(in: href)
        else { return false }
        guard let target = resolveFragment(fragment, in: controller.textStorage) else {
            return false
        }
        navigate(controller: controller, to: target)
        return true
    }

    private func linkHref(at charIndex: Int, in storage: NSAttributedString) -> String? {
        // The click handler on macOS reports `characterIndexForInsertion`,
        // which sits *between* characters — probe both sides so a tap on the
        // very last character of a link still resolves.
        for probe in [charIndex, charIndex - 1] where probe >= 0 && probe < storage.length {
            guard let marks = storage.markSet(at: probe),
                  let link = marks.mark(of: "link"),
                  case let .string(href) = link.attrs["href"] ?? .null,
                  !href.isEmpty
            else { continue }
            return href
        }
        return nil
    }

    /// Returns the fragment portion if `href` is a same-document anchor
    /// (`#foo`, or `./page.md#foo` with no scheme). External URLs return nil
    /// so the OS still gets a shot at opening them.
    private func fragmentTarget(in href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        if href[..<hash].contains("://") { return nil }
        let frag = href[href.index(after: hash)...]
        return frag.isEmpty ? nil : String(frag)
    }

    /// Walk `proseNodePath` runs whose deepest node is a heading; slugify the
    /// heading's text and compare. Returns the storage range covering the
    /// heading body.
    internal func resolveFragment(_ fragment: String, in storage: NSAttributedString) -> NSRange? {
        let target = slugify(fragment)
        var hit: NSRange?
        storage.enumerateNodePaths { runRange, path in
            guard hit == nil,
                  let leaf = path.leaf, leaf.type == "heading"
            else { return }
            let headingRange = expandToWholeNode(leaf.id, hint: runRange, in: storage)
            let body = (storage.string as NSString).substring(with: headingRange)
            if slugify(body) == target { hit = headingRange }
        }
        return hit
    }

    /// Adjacent `proseNodePath` runs inside the same heading share the
    /// heading's `NodeID` at their deepest level (mark splits don't change
    /// structural identity). Expand `hint` left and right so the slug is
    /// computed over the whole heading body, not just one mark run.
    private func expandToWholeNode(
        _ id: NodeID,
        hint: NSRange,
        in storage: NSAttributedString
    ) -> NSRange {
        var start = hint.location
        var end = hint.location + hint.length
        while start > 0,
              let p = storage.nodePath(at: start - 1),
              p.leaf?.id == id { start -= 1 }
        while end < storage.length,
              let p = storage.nodePath(at: end),
              p.leaf?.id == id { end += 1 }
        // The compiler emits a trailing "\n" inside the heading's path so
        // the next block starts on a fresh line. Drop it from the range we
        // return — callers want the heading body, not the separator.
        let ns = storage.string as NSString
        while end > start, ns.character(at: end - 1) == 0x0A { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private func navigate(controller: EditorController, to range: NSRange) {
        // Same shape as Lino's TOC navigation: scroll the host text view
        // directly and place a collapsed cursor at the heading start.
        // No transaction is recorded (this is navigation, not an edit).
        let head = NSRange(location: range.location, length: 0)
        controller.setSelection(head)
        #if canImport(AppKit) && os(macOS)
        if let tv = controller.hostTextView as? NSTextView {
            tv.scrollRangeToVisible(range)
            tv.window?.makeFirstResponder(tv)
        }
        #elseif canImport(UIKit)
        if let tv = controller.hostTextView as? UITextView {
            tv.scrollRangeToVisible(range)
            tv.becomeFirstResponder()
        }
        #endif
    }

    internal func slugify(_ s: String) -> String {
        switch slugStyle {
        case .exact: return s
        case .github:
            var out = ""
            out.reserveCapacity(s.count)
            for scalar in s.lowercased().unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    out.unicodeScalars.append(scalar)
                } else if !out.hasSuffix("-") {
                    out.append("-")
                }
            }
            while out.hasPrefix("-") { out.removeFirst() }
            while out.hasSuffix("-") { out.removeLast() }
            return out
        }
    }
}
