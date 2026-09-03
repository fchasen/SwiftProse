import Foundation
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One occurrence of an `InlineContentRule` in the markdown source.
public struct InlineContentMatch: Sendable {
    /// The whole matched substring, verbatim. This is what the serializer
    /// re-emits, so the round trip is byte-exact.
    public let matched: String
    /// Capture groups, index 0 being the whole match. `nil` where the group
    /// didn't participate.
    public let groups: [String?]

    public init(matched: String, groups: [String?]) {
        self.matched = matched
        self.groups = groups
    }

    public func capture(_ index: Int) -> String? {
        guard groups.indices.contains(index) else { return nil }
        return groups[index]
    }
}

/// A host-supplied regex that turns a span of markdown source into inline
/// content: the compiler removes the matched characters from the displayed
/// text and splices a single object-replacement character carrying the
/// attachment `EditorController.inlineContentProvider` returns for
/// `content(match)`.
///
/// Unlike `AutoLinkRule`, this runs inside the compiler rather than as a
/// plugin, so it also fires on `setMarkdown` — a document loaded from the host
/// renders its inline content immediately, without an intervening edit.
public struct InlineContentRule: Sendable {
    public let id: String
    public let pattern: String
    public let content: @Sendable (InlineContentMatch) -> ProseInlineContent?

    /// Compiled once at init. `NSRegularExpression` is documented as thread-safe
    /// for matching, so sharing one across the main and background compilers is fine.
    let regex: NSRegularExpression

    public init(
        id: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        content: @escaping @Sendable (InlineContentMatch) -> ProseInlineContent?
    ) {
        self.id = id
        self.pattern = pattern
        do {
            self.regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("InlineContentRule \(id) pattern \(pattern) failed to compile: \(error)")
        }
        self.content = content
    }
}

/// Turns the content a rule produced into the attachment that stands in for it
/// in storage. Hosts install one with `.inlineContentProvider(_:)`; without one
/// the rules never fire and the source stays visible.
///
/// Called on whichever queue is compiling — including the background compile
/// queue — so build the attachment lazily (`NSTextAttachment` subclasses draw
/// from `image(forBounds:textContainer:characterIndex:)`, which TextKit calls
/// on the main thread) rather than rendering an image here.
/// Not `@Sendable`: `NSTextAttachment` isn't, and neither is `AutoLinkRule`'s
/// closure pair. It does cross to the compile queue, so treat it as callable
/// from any thread.
public typealias ProseInlineContentProvider = (ProseInlineContent) -> NSTextAttachment?

/// The node type the compiler stamps for a matched rule, and the serializer
/// reads `raw` back off.
public enum InlineContentNode {
    public static let type = "inline_content"
    public static let kindAttr = "kind"
    public static let rawAttr = "raw"
}
