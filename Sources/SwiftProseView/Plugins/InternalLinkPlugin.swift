import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Path + fragment parsed out of a relative link href. Either piece may be
/// absent — pure-fragment hrefs (`#foo`) are handled locally by the plugin
/// and never produce a `LinkTarget`.
public struct LinkTarget: Sendable, Equatable {
    /// Path portion of the href, percent-decoded when possible. Examples:
    /// `"./other.md"`, `"subdir/foo.md"`, `"../bar.md"`, `"foo bar.md"`.
    public let path: String
    /// Fragment after `#`, percent-decoded when possible. Nil if absent.
    public let fragment: String?

    public init(path: String, fragment: String?) {
        self.path = path
        self.fragment = fragment
    }
}

/// Resolves clicks on `[text](#anchor)` links to a position in the same
/// document. ProseMirror leaves anchor handling to the browser; in a native
/// text editor the OS would just hand `#anchor` to NSWorkspace / UIApplication
/// (no-op or error). This plugin intercepts the click before the OS sees it,
/// matches the fragment against a heading slug, and scrolls / selects.
///
/// Hosts that want to follow relative path links (`./other.md`,
/// `subdir/foo.md#section`) can pass `handleRelativeLink` to opt into
/// cross-document navigation — the host gets a `LinkTarget` and decides
/// whether to consume the click. External hrefs (`http://`, `mailto:`, etc.)
/// and unresolved fragments fall through to default OS handling.
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
    private let handleRelativeLink: ((LinkTarget) -> Bool)?

    public init(
        slugStyle: SlugStyle = .github,
        handleRelativeLink: ((LinkTarget) -> Bool)? = nil
    ) {
        self.slugStyle = slugStyle
        self.handleRelativeLink = handleRelativeLink
    }

    public var props: PluginProps {
        PluginProps(handleClick: { [weak self] controller, charIndex in
            self?.handleClick(controller: controller, at: charIndex) ?? false
        })
    }

    private func handleClick(controller: EditorController, at charIndex: Int) -> Bool {
        guard let href = linkHref(at: charIndex, in: controller.textStorage),
              !href.isEmpty,
              !isExternalScheme(href)
        else { return false }

        // Pure same-document fragment: `#anchor`.
        if href.hasPrefix("#") {
            return navigateToFragment(String(href.dropFirst()), controller: controller)
        }

        // Relative reference (with optional `#fragment`). Hand off to the
        // host — it owns filesystem / library context. If the host doesn't
        // claim the click, fall through so the OS gets its usual shot.
        guard let target = parseRelativeLink(href),
              let handler = handleRelativeLink
        else { return false }
        return handler(target)
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

    /// True iff `href` starts with a well-formed URI scheme (e.g. `http`,
    /// `mailto`, `file`). Anything else — pure fragments, bare filenames,
    /// `./x`, `../x`, even `/abs/path` — is treated as host-resolvable.
    /// Matches RFC 3986 scheme grammar: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":".
    internal func isExternalScheme(_ href: String) -> Bool {
        guard let colon = href.firstIndex(of: ":") else { return false }
        let scheme = href[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
        }
    }

    /// Splits a relative href into path + fragment, percent-decoding both
    /// so hosts can compare against filesystem paths directly. Returns nil
    /// for pure-fragment hrefs (those are handled locally upstream).
    internal func parseRelativeLink(_ href: String) -> LinkTarget? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        guard !rawPath.isEmpty else { return nil }
        let rawFrag: String? = parts.count > 1 ? String(parts[1]) : nil
        return LinkTarget(
            path: rawPath.removingPercentEncoding ?? rawPath,
            fragment: rawFrag.map { $0.removingPercentEncoding ?? $0 }
        )
    }

    private func navigateToFragment(_ fragment: String, controller: EditorController) -> Bool {
        guard !fragment.isEmpty,
              let target = resolveFragment(fragment, in: controller.textStorage)
        else { return false }
        navigate(controller: controller, to: target)
        return true
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
