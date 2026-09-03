import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// An `inline_content` leaf ends its `proseNodePath` one level below the line's
/// block, and its whole source lives in the node's `raw` attr rather than in
/// storage. Every pass that collapses a line onto one path has to lift those
/// runs out first and re-hang them afterwards; overwrite one and
/// `ProseDocument.from(storage:)` stops seeing a leaf, so the source is gone.
///
/// Only `inline_content`. An image's leaf covers its alt text, which is
/// ordinary editable content — lifting it would re-hang characters typed into
/// the alt run onto the image node and lose them.
enum InlineLeafRuns {

    static func isLiftable(_ type: String) -> Bool {
        type == InlineContentNode.type
    }

    static func isLiftable(_ node: ProseNode?) -> Bool {
        guard let node else { return false }
        return isLiftable(node.type)
    }

    /// Splits `range` into maximal runs of object-replacement characters and
    /// maximal runs of everything else, in document order.
    static func splitAtAttachments(
        _ range: NSRange,
        in string: NSString
    ) -> [(range: NSRange, isAttachment: Bool)] {
        var out: [(range: NSRange, isAttachment: Bool)] = []
        var start = range.location
        var index = range.location
        var current: Bool?
        while index < NSMaxRange(range) {
            let isAttachment = string.character(at: index) == 0xFFFC
            if current == nil {
                current = isAttachment
            } else if current != isAttachment {
                out.append((NSRange(location: start, length: index - start), current!))
                start = index
                current = isAttachment
            }
            index += 1
        }
        if let current, index > start {
            out.append((NSRange(location: start, length: index - start), current))
        }
        return out
    }

    /// The liftable runs covering `range`, alongside the characters that share
    /// a leaf's attribute run without belonging to it.
    ///
    /// The leaf is exactly its attachment character. Text typed against its
    /// edges inherits its attributes and joins the run; left there, the reverse
    /// projection swallows it into the leaf.
    static func capture(
        in storage: NSAttributedString,
        range: NSRange
    ) -> (leaves: [(range: NSRange, node: ProseNode)], demoted: [NSRange]) {
        var leaves: [(range: NSRange, node: ProseNode)] = []
        var demoted: [NSRange] = []
        let string = storage.string as NSString
        storage.enumerateAttribute(.proseNodePath, in: range) { value, runRange, _ in
            guard let box = value as? NodePathBox,
                  let leaf = box.path.leaf,
                  isLiftable(leaf.type) else { return }
            for piece in splitAtAttachments(runRange, in: string) {
                if piece.isAttachment {
                    leaves.append((piece.range, leaf))
                } else {
                    demoted.append(piece.range)
                }
            }
        }
        return (leaves, demoted)
    }

    /// Re-hang captured leaves off whatever path their line settled on.
    ///
    /// The parent comes from the line, not from the leaf's own run: the run may
    /// still hold the pre-collapse path, and hanging the leaf off that is what
    /// splits one paragraph into two. Reusing the captured `ProseNode` keeps the
    /// leaf's `NodeID`.
    static func restamp(
        _ runs: [(range: NSRange, node: ProseNode)],
        in storage: NSTextStorage,
        lineRange: NSRange
    ) {
        guard !runs.isEmpty else { return }
        var base: NodePath?
        var index = lineRange.location
        while index < min(NSMaxRange(lineRange), storage.length) {
            if let path = storage.nodePath(at: index), !isLiftable(path.leaf) {
                base = path
                break
            }
            index += 1
        }
        for (range, node) in runs {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            var parent = base
            if parent == nil, var own = storage.nodePath(at: range.location) {
                if isLiftable(own.leaf) { own = own.droppingLast() }
                parent = own
            }
            guard let parent else { continue }
            storage.setNodePath(parent.appending(node), in: range)
        }
    }
}
