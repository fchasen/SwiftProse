import Foundation
import SwiftProseSyntax
import SwiftProseRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct Decoration: Equatable, Sendable {
    public let range: NSRange
    public let kind: DecorationKind
    public let zIndex: Int

    public init(range: NSRange, kind: DecorationKind, zIndex: Int = 0) {
        self.range = range
        self.kind = kind
        self.zIndex = zIndex
    }
}

public enum DecorationKind: Equatable, Sendable {
    case blockquoteBar(depth: Int, position: RunPosition)
    case codeBackground(language: String?, position: RunPosition)
    /// Emitted for paragraphs whose `proseNodePath` ends in
    /// `horizontal_rule`. The bundled layout-manager doesn't dispatch on
    /// this — the rule is rendered by `HorizontalRuleAttachment` in
    /// storage — but it remains in the public surface so host
    /// `DecorationProvider`s can layer their own chrome.
    case horizontalRule
}

public enum RunPosition: Equatable, Sendable {
    case start
    case middle
    case end
    case single
}

public protocol DecorationProvider: AnyObject {
    func decorations(in range: NSRange, storage: NSAttributedString) -> [Decoration]
}

/// Aggregates multiple `DecorationProvider`s into one. Decorations from
/// each provider are concatenated; downstream consumers sort by zIndex
/// when painting so layering stays predictable across providers.
public final class DecorationSet: DecorationProvider {
    public private(set) var providers: [DecorationProvider] = []

    public init(_ providers: [DecorationProvider] = []) {
        self.providers = providers
    }

    public func add(_ provider: DecorationProvider) {
        providers.append(provider)
    }

    public func remove(_ provider: DecorationProvider) {
        providers.removeAll { $0 === provider }
    }

    public func decorations(in range: NSRange, storage: NSAttributedString) -> [Decoration] {
        var out: [Decoration] = []
        for provider in providers {
            out.append(contentsOf: provider.decorations(in: range, storage: storage))
        }
        return out
    }
}

/// Decoration provider that reads `proseNodePath` to derive structural
/// chrome (blockquote bars, code backgrounds, hr lines). Walks paragraph
/// by paragraph; for each, inspects the path's ancestors and leaf type.
public final class BlockSpecDecorationProvider: DecorationProvider {

    public init() {}

    public func decorations(
        in range: NSRange,
        storage: NSAttributedString
    ) -> [Decoration] {
        guard storage.length > 0 else { return [] }
        let ns = storage.string as NSString
        var out: [Decoration] = []
        var cursor = range.location
        let end = max(range.location, range.location + range.length)
        while cursor < ns.length {
            let line = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            decorate(line: line, in: storage, into: &out)
            let next = line.location + line.length
            if next == cursor { break }
            cursor = next
            if cursor >= end && range.length > 0 { break }
        }
        return out
    }

    private func decorate(
        line: NSRange,
        in storage: NSAttributedString,
        into out: inout [Decoration]
    ) {
        // Scan the paragraph for any character carrying a node path —
        // trusting char 0 only would miss lines where the leading
        // character lost its path mid-edit.
        guard let path = paragraphPath(in: storage, lineRange: line) else { return }
        let depth = blockquoteDepth(in: path)
        if depth > 0 {
            let position = runPosition(for: line, in: storage) { p in blockquoteDepth(in: p) > 0 }
            out.append(Decoration(range: line, kind: .blockquoteBar(depth: depth, position: position)))
        }
        guard let leaf = path.leaf else { return }
        switch leaf.type {
        case "code_block":
            let params = leaf.attrs["params"]?.stringValue
            let language = (params?.isEmpty == false) ? params : nil
            let position = runPosition(for: line, in: storage) { p in
                p.leaf?.type == "code_block"
            }
            out.append(Decoration(range: line, kind: .codeBackground(language: language, position: position), zIndex: -1))
        case "horizontal_rule":
            out.append(Decoration(range: line, kind: .horizontalRule))
        default:
            break
        }
    }

    private func paragraphPath(in storage: NSAttributedString, lineRange: NSRange) -> NodePath? {
        var i = lineRange.location
        let end = lineRange.location + lineRange.length
        while i < end {
            if let path = storage.nodePath(at: i) { return path }
            i += 1
        }
        return nil
    }

    private func blockquoteDepth(in path: NodePath) -> Int {
        path.nodes.reduce(0) { $0 + ($1.type == "blockquote" ? 1 : 0) }
    }

    private func runPosition(
        for line: NSRange,
        in storage: NSAttributedString,
        match: (NodePath) -> Bool
    ) -> RunPosition {
        let prevMatches = linePath(before: line, in: storage).map(match) ?? false
        let nextMatches = linePath(after: line, in: storage).map(match) ?? false
        switch (prevMatches, nextMatches) {
        case (false, false): return .single
        case (false, true): return .start
        case (true, false): return .end
        case (true, true): return .middle
        }
    }

    private func linePath(before line: NSRange, in storage: NSAttributedString) -> NodePath? {
        guard line.location > 0 else { return nil }
        return storage.nodePath(at: line.location - 1)
    }

    private func linePath(after line: NSRange, in storage: NSAttributedString) -> NodePath? {
        let end = line.location + line.length
        guard end < storage.length else { return nil }
        return storage.nodePath(at: end)
    }
}
