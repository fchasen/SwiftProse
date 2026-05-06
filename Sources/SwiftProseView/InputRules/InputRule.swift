import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A pattern that fires a `Transaction` when text typed before the cursor
/// matches its regex. Modeled after `prosemirror-inputrules`: an `InputRule`
/// is a peer of `Command` rather than a subtype — commands are dispatched
/// explicitly with a selection range, input rules are dispatched implicitly
/// by typing and receive regex capture groups.
public struct InputRule {
    public let id: String
    public let pattern: NSRegularExpression
    public let handler: (Match) -> Transaction?
    /// How this rule handles cursors inside a code block. PM convention:
    /// inline-mark rules (bold, italic, codeSpan) `.skip` so the user
    /// can type `*` literally inside `code_block`. Block-shape rules
    /// (heading, list) default to `.run` since they're already inert
    /// when the cursor is mid-code-block (the regex anchors at start of
    /// line, which a code block usually doesn't satisfy).
    public let inCode: InCodePolicy

    public enum InCodePolicy: Sendable, Equatable {
        case run    // evaluate the rule normally
        case skip   // never fire when the cursor is inside a code block
    }

    public init(
        id: String,
        pattern: NSRegularExpression,
        inCode: InCodePolicy = .run,
        handler: @escaping (Match) -> Transaction?
    ) {
        self.id = id
        self.pattern = pattern
        self.inCode = inCode
        self.handler = handler
    }

    /// Convenience: build a rule from a regex string. Crashes if the pattern
    /// fails to compile — the call sites are static rule definitions, not
    /// runtime input.
    public init(
        id: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        inCode: InCodePolicy = .run,
        handler: @escaping (Match) -> Transaction?
    ) {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("InputRule \(id) pattern \(pattern) failed to compile: \(error)")
        }
        self.init(id: id, pattern: regex, inCode: inCode, handler: handler)
    }

    /// What the runner hands the rule's handler. Ranges are storage-absolute
    /// (already shifted from prefix-relative coordinates).
    public struct Match {
        public let storage: NSTextStorage
        public let lineRange: NSRange
        public let lineText: String
        public let matchedRange: NSRange
        public let captureRanges: [NSRange]
        public let cursor: Int
        public let env: StepEnvironment

        /// The captured substring at index `i`, or `nil` if the group did not
        /// participate. Index 0 is the full match.
        public func capture(_ i: Int) -> String? {
            guard captureRanges.indices.contains(i) else { return nil }
            let range = captureRanges[i]
            guard range.location != NSNotFound else { return nil }
            let ns = storage.string as NSString
            guard range.location + range.length <= ns.length else { return nil }
            return ns.substring(with: range)
        }
    }
}

// MARK: - PM-style helpers
//
// Wrap a paragraph (or other block) into a list / blockquote / etc.
// when its prefix matches a regex. Mirrors prosemirror-inputrules'
// `wrappingInputRule`. Translates the matched line into a `setSpec` of
// the supplied target spec.
public func wrappingInputRule(
    id: String,
    pattern: String,
    options: NSRegularExpression.Options = [],
    target: @escaping (InputRule.Match) -> BlockSpec
) -> InputRule {
    InputRule(id: id, pattern: pattern, options: options) { match in
        let spec = target(match)
        return Transaction(
            steps: [.setSpec(lineRange: match.lineRange, spec)],
            label: "Wrap \(id)"
        )
    }
}

/// Mirrors `textblockTypeInputRule`. Sets the matched line's block kind
/// to `kind` (e.g. heading from `^# `).
public func textblockTypeInputRule(
    id: String,
    pattern: String,
    options: NSRegularExpression.Options = [],
    kind: BlockSpec.Kind
) -> InputRule {
    InputRule(id: id, pattern: pattern, options: options) { match in
        let current = match.storage.blockSpec(at: match.lineRange.location) ?? .paragraph
        let spec = BlockSpec(kind: kind, blockquoteDepth: current.blockquoteDepth, listLevel: current.listLevel)
        return Transaction(
            steps: [.setSpec(lineRange: match.lineRange, spec)],
            label: "Set \(id)"
        )
    }
}
