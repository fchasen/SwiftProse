import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Splice-based reuse of a previously projected `ProseDocument`.
///
/// `ProseDocument.from(storage:)` is O(document) and does two attribute
/// lookups per character, so a host that mirrors the typed tree pays the
/// whole document on every keystroke. Almost none of it changed.
///
/// This tracks the edits made since the cached tree was projected as a
/// `Mapping`, re-projects only the top-level blocks that edit touched, and
/// splices the result over the stale children. Every node's exact storage
/// span is on `ProseNode.layout` (Stage 2), so the block boundaries are
/// known without measuring anything.
///
/// It is a pure optimization: `spliced(...)` returns nil whenever it is not
/// certain, and the caller falls back to a full projection.
struct IncrementalProjection {

    /// The tree as last projected, and the edits made to storage since.
    private(set) var cached: ProseDocument?
    private var mapping = Mapping.empty
    /// Union of every edited range, in *current storage* coordinates.
    private var dirty: NSRange?

    /// Adopt a freshly projected tree; no edits outstanding.
    mutating func adopt(_ document: ProseDocument) {
        cached = document
        mapping = .empty
        dirty = nil
    }

    /// Forget everything — the next read re-projects in full.
    mutating func reset() {
        cached = nil
        mapping = .empty
        dirty = nil
    }

    var hasPendingEdits: Bool { dirty != nil }

    /// Record a storage edit. `editedRange` is post-edit.
    mutating func record(editedRange: NSRange, changeInLength: Int) {
        guard cached != nil else { return }
        let preLength = max(0, editedRange.length - changeInLength)
        let preRange = NSRange(location: editedRange.location, length: preLength)
        let map = StepMap(oldRange: preRange, newLength: editedRange.length)

        // Carry the existing dirty range through this edit, then union.
        if let existing = dirty {
            let moved = map.mapRange(existing)
            let lo = min(moved.location, editedRange.location)
            let hi = max(moved.location + moved.length, editedRange.location + editedRange.length)
            dirty = NSRange(location: lo, length: hi - lo)
        } else {
            dirty = editedRange
        }
        mapping.append(map)
    }

    /// The tree for `storage`, reusing what it can. Nil means "re-project".
    func spliced(
        storage: NSAttributedString,
        schema: Schema
    ) -> ProseDocument? {
        guard let cached else { return nil }
        guard let dirty else { return cached }
        guard case .structural(let rootNode, let children) = cached.root else { return nil }
        guard !children.isEmpty else { return nil }

        // Every child must know its own storage span, or the boundaries
        // below are guesses.
        var bounds: [NSRange] = []
        bounds.reserveCapacity(children.count)
        var offset = 0
        for child in children {
            guard let span = child.node?.layout.storageLength else { return nil }
            bounds.append(NSRange(location: offset, length: span))
            offset += span
        }
        // The cached tree must have described the whole pre-edit buffer.
        let preLength = mapping.invert().map(storage.length)
        guard offset == preLength else { return nil }

        // Dirty range back in the cached tree's coordinates.
        let inverse = mapping.invert()
        let dirtyPre = inverse.mapRange(dirty)

        guard var lo = bounds.firstIndex(where: {
            $0.location + $0.length > dirtyPre.location
        }) else { return nil }
        var hi = bounds.lastIndex(where: {
            $0.location < max(dirtyPre.location + dirtyPre.length, dirtyPre.location + 1)
        }) ?? lo
        guard hi >= lo else { return nil }

        // One block of slack on each side: an edit at a boundary can merge
        // two blocks or split one, and a list's continuity with the block
        // after it is decided by the node ids the compiler stamped.
        lo = max(0, lo - 1)
        hi = min(children.count - 1, hi + 1)

        // Map the affected span into current storage.
        let preSpan = NSRange(
            location: bounds[lo].location,
            length: bounds[hi].location + bounds[hi].length - bounds[lo].location
        )
        let postStart = mapping.map(preSpan.location, bias: .before)
        let postEnd = mapping.map(preSpan.location + preSpan.length, bias: .after)
        guard postStart >= 0, postEnd <= storage.length, postEnd >= postStart else { return nil }
        let postSpan = NSRange(location: postStart, length: postEnd - postStart)

        // Re-project just that span and splice its children in.
        let patch = ProseDocument.from(storage: storage, range: postSpan, schema: schema)
        guard case .structural(_, let fresh) = patch.root else { return nil }

        var merged: [TreeNode] = []
        merged.reserveCapacity(children.count - (hi - lo + 1) + fresh.count)
        merged.append(contentsOf: children[0..<lo])
        merged.append(contentsOf: fresh)
        merged.append(contentsOf: children[(hi + 1)...])

        // The splice is only valid if the pieces still tile the buffer.
        var total = 0
        for child in merged {
            guard let span = child.node?.layout.storageLength else { return nil }
            total += span
        }
        guard total == storage.length else { return nil }

        // The root keeps its identity but not its stale span.
        var root = rootNode
        root.layout.storageLength = total
        return ProseDocument(schema: schema, root: .structural(root, merged))
    }
}
