import Foundation
import SwiftProseSyntax

/// Typed selection mirroring ProseMirror's `Selection` family.
///
/// - `text(range, anchor, head)` is the common cursor / range selection;
///   `anchor` and `head` are character offsets, with `anchor == head`
///   meaning a collapsed cursor at that position.
/// - `node(path, range)` selects a single structural node — used by
///   commands like Backspace-on-an-HR (PM's `NodeSelection`).
/// - `all` is the document-spanning selection (PM's `AllSelection`,
///   distinct from a `text` selection that happens to cover everything).
///
/// Hosts that only need positional info can read `selectedRange`; hosts
/// that need to know whether the user has a node selected (e.g. to show
/// an HR drag handle, or to delete-on-Backspace) inspect the case.
public enum Selection: Equatable, Sendable {
    case text(range: NSRange, anchor: Int, head: Int)
    case node(path: NodePath, range: NSRange)
    case all

    /// The character range covered by this selection. For `node`, the
    /// range that backs the node in storage. `all` can't know the document
    /// length here, so it reports an empty range — use
    /// `resolvedRange(documentLength:)` when the selection may be `all`.
    public var selectedRange: NSRange {
        switch self {
        case .text(let range, _, _): return range
        case .node(_, let range): return range
        case .all: return NSRange(location: 0, length: 0)
        }
    }

    /// Resolve to a concrete character range against a document of
    /// `documentLength`. `all` spans the whole document; `text` / `node`
    /// return their stored range. Prefer this over `selectedRange` when the
    /// selection may be `all`.
    public func resolvedRange(documentLength: Int) -> NSRange {
        switch self {
        case .text(let range, _, _): return range
        case .node(_, let range): return range
        case .all: return NSRange(location: 0, length: documentLength)
        }
    }

    public var isCollapsed: Bool {
        switch self {
        case .text(_, let a, let h): return a == h
        case .node, .all: return false
        }
    }

    /// Convenience for the most common case — a collapsed text cursor.
    public static func cursor(at pos: Int) -> Selection {
        .text(range: NSRange(location: pos, length: 0), anchor: pos, head: pos)
    }

    /// Convenience for an extended text selection.
    public static func textRange(_ range: NSRange) -> Selection {
        let head = range.location + range.length
        return .text(range: range, anchor: range.location, head: head)
    }
}
