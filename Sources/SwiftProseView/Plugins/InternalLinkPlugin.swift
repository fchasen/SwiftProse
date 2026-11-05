import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Path and fragment parsed from a relative link href. Pure-fragment hrefs
/// (`#foo`) are resolved by the plugin and never produce a `LinkTarget`.
public struct LinkTarget: Sendable, Equatable {
    /// Path portion of the href, percent-decoded when possible.
    public let path: String
    /// Fragment after `#`, percent-decoded when possible.
    public let fragment: String?

    public init(path: String, fragment: String?) {
        self.path = path
        self.fragment = fragment
    }
}

/// Resolves clicks on `[text](#anchor)` links to the heading whose slug
/// matches the fragment, then selects and scrolls to it.
///
/// `handleRelativeLink` receives relative path links (`./other.md`,
/// `subdir/foo.md#section`) and returns `true` to consume the click.
/// External hrefs (`http://`, `mailto:`) and unresolved fragments fall
/// through to the platform's default link handling.
public final class InternalLinkPlugin: EditorPlugin {
    public static let keyName = "swiftprose.internalLink"
    public let key = AnyPluginKey(name: keyName)

    /// Heading slug strategy. `.github` lowercases, maps runs of
    /// non-alphanumerics to one dash and trims dashes; `.exact` compares
    /// the heading text verbatim.
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
        PluginProps(handleClick: { [weak self] controller, index in
            self?.handleClick(controller: controller, at: index) ?? false
        })
    }

    private func handleClick(controller: EditorController, at index: Int) -> Bool {
        guard let href = linkHref(at: index, in: controller.textStorage),
              !href.isEmpty,
              !isExternalScheme(href)
        else { return false }
        if href.hasPrefix("#") {
            return navigateToFragment(String(href.dropFirst()), controller: controller)
        }
        guard let target = parseRelativeLink(href), let handler = handleRelativeLink else { return false }
        return handler(target)
    }

    private func linkHref(at index: Int, in storage: NSAttributedString) -> String? {
        for probe in [index, index - 1] where probe >= 0 && probe < storage.length {
            if let href = storage.markdownLink(at: probe), !href.isEmpty { return href }
        }
        return nil
    }

    /// RFC 3986 scheme grammar: `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"`.
    func isExternalScheme(_ href: String) -> Bool {
        guard let colon = href.firstIndex(of: ":") else { return false }
        let scheme = href[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    func parseRelativeLink(_ href: String) -> LinkTarget? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        guard !rawPath.isEmpty else { return nil }
        let rawFragment: String? = parts.count > 1 ? String(parts[1]) : nil
        return LinkTarget(
            path: rawPath.removingPercentEncoding ?? rawPath,
            fragment: rawFragment.map { $0.removingPercentEncoding ?? $0 }
        )
    }

    private func navigateToFragment(_ fragment: String, controller: EditorController) -> Bool {
        guard !fragment.isEmpty, let target = resolveFragment(fragment, in: controller.textStorage) else { return false }
        navigate(controller: controller, to: target)
        return true
    }

    /// The content range of the first heading whose slug matches `fragment`.
    func resolveFragment(_ fragment: String, in storage: NSAttributedString) -> NSRange? {
        let target = slugify(fragment)
        let ns = storage.string as NSString
        for paragraph in storage.markdownParagraphRanges() where paragraph.length > 0 {
            guard storage.markdownBlock(at: paragraph.location)?.headingLevel != nil else { continue }
            var content = paragraph
            while content.length > 0, ns.character(at: NSMaxRange(content) - 1) == MarkdownParagraph.separator {
                content.length -= 1
            }
            if slugify(ns.substring(with: content)) == target { return content }
        }
        return nil
    }

    private func navigate(controller: EditorController, to range: NSRange) {
        controller.setSelection(NSRange(location: range.location, length: 0))
        #if canImport(AppKit) && os(macOS)
        if let textView = controller.hostTextView {
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }
        #elseif canImport(UIKit)
        if let textView = controller.hostTextView {
            textView.scrollRangeToVisible(range)
            textView.becomeFirstResponder()
        }
        #endif
    }

    func slugify(_ text: String) -> String {
        switch slugStyle {
        case .exact:
            return text
        case .github:
            var out = ""
            out.reserveCapacity(text.count)
            for scalar in text.lowercased().unicodeScalars {
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
