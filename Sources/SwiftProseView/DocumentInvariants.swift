import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Structural rules that hold across a *run* of blocks, not within one
/// line — the ones a line-local repair pass cannot see.
///
/// Block structure is not line-local: deleting the first item of an
/// ordered list renumbers every item after it, and outdenting one item can
/// orphan the ones nested under it. `SpecValidator` checks each line in
/// isolation and so is blind to all of this. These run over the structural
/// run containing an edit.
///
/// Three invariants:
///
/// - **Ordered numbering.** Contiguous `orderedListItem` lines at the same
///   `listLevel` and `blockquoteDepth` are one list, numbered 1, 2, 3 …
///   — the same normalization the compiler and the markdown serializer
///   already apply to an authored start of any other number.
/// - **List level.** An item never sits more than one level deeper than
///   the item before it; a deeper jump is an orphan with no parent item.
/// - **Blockquote depth.** Same rule for `blockquoteDepth`.
enum DocumentInvariants {

    /// Bring the structural run containing `range` back to its invariants.
    /// Returns true when anything changed.
    @discardableResult
    static func enforce(
        in storage: NSTextStorage,
        around range: NSRange,
        env: StepEnvironment
    ) -> Bool {
        let run = structuralRun(in: storage, around: range)
        guard run.length > 0 else { return false }

        let corrected = correctedSpecs(in: storage, run: run)
        guard corrected.contains(where: { $0 != nil }) else { return false }

        // Apply front to back, re-deriving each line range as we go: a
        // marker change ("9. " → "10. ") shifts everything after it, and
        // `setBlockSpec` reuses the *predecessor's* list ancestors, so the
        // earlier lines have to be settled first.
        var changed = false
        var cursor = run.location
        var index = 0
        let ns0 = storage.string as NSString
        var remaining = min(run.length, ns0.length - run.location)
        while index < corrected.count, cursor < storage.length, remaining > 0 {
            let ns = storage.string as NSString
            let line = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            guard line.length > 0 else { break }
            let target = corrected[index]
            let current = storage.blockSpec(at: line.location)
            if let target, current != target {
                let applied = Step.setSpecPreservingLineTerminator(lineRange: line, target)
                    .apply(to: storage, env: env)
                changed = true
                let newLength = applied.mappedRange.length
                remaining += newLength - line.length
                cursor = line.location + newLength
            } else {
                cursor = line.location + line.length
            }
            remaining -= (cursor - line.location)
            index += 1
        }
        return changed
    }

    // MARK: - run discovery

    /// The maximal contiguous span of list / blockquote lines containing
    /// `range`. A plain paragraph at depth 0 terminates the run — that is
    /// where one list ends and the next begins.
    static func structuralRun(in storage: NSTextStorage, around range: NSRange) -> NSRange {
        let total = storage.length
        guard total > 0 else { return NSRange(location: 0, length: 0) }
        let ns = storage.string as NSString
        let safe = range.clamped(to: total)
        let seed = ns.paragraphRange(
            for: NSRange(location: min(safe.location, max(0, total - 1)), length: max(0, min(safe.length, total - safe.location)))
        )
        guard seed.length > 0 else { return NSRange(location: 0, length: 0) }

        var start = seed.location
        while start > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: start - 1, length: 0))
            guard previous.length > 0, isStructural(storage.blockSpec(at: previous.location)) else { break }
            start = previous.location
        }
        var end = seed.location + seed.length
        while end < total {
            let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
            guard next.length > 0, isStructural(storage.blockSpec(at: next.location)) else { break }
            end = next.location + next.length
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isStructural(_ spec: BlockSpec?) -> Bool {
        guard let spec else { return false }
        return spec.isListItem || spec.blockquoteDepth > 0
    }

    // MARK: - correction

    /// Walk the run and compute what each line's spec should be, or `nil`
    /// for lines this pass must not touch.
    ///
    /// Only list items and blockquote lines are corrected. A line with no
    /// spec yet — a character typed into an empty document, before
    /// anything has classified it — is left strictly alone: re-rendering
    /// it through the compiler would interpret its raw text as markdown
    /// and eat it.
    private static func correctedSpecs(in storage: NSTextStorage, run: NSRange) -> [BlockSpec?] {
        let ns = storage.string as NSString
        var out: [BlockSpec?] = []
        var cursor = run.location
        let end = run.location + run.length

        // `nil` until a structural line has been seen: the first line of a
        // run establishes its own depth, and a document may legitimately
        // open at `> > `.
        var previousListLevel: Int?
        var previousQuoteDepth: Int?
        // Running counter per (level, blockquoteDepth) for the ordered list
        // currently open at that level.
        var counters: [Key: Int] = [:]

        while cursor < end, cursor < storage.length {
            let line = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            guard line.length > 0 else { break }
            guard var spec = storage.blockSpec(at: line.location),
                  spec.isListItem || spec.blockquoteDepth > 0 else {
                out.append(nil)
                counters.removeAll()
                previousListLevel = nil
                previousQuoteDepth = nil
                cursor = line.location + line.length
                continue
            }

            // Blockquote depth may not jump by more than one past the
            // line above it.
            let quoteDepth = previousQuoteDepth
                .map { min(spec.blockquoteDepth, $0 + 1) } ?? spec.blockquoteDepth
            // Nor may list level — a deeper jump is an item with no parent.
            var listLevel = spec.listLevel
            if spec.isListItem {
                listLevel = max(0, previousListLevel.map { min(listLevel, $0 + 1) } ?? listLevel)
            }

            if spec.isListItem, case .orderedListItem(let storedIndex) = spec.kind {
                let key = Key(level: listLevel, quote: quoteDepth)
                // Any line at this level that isn't an ordered item ends the
                // list; so does a shallower line.
                let next: Int
                if let running = counters[key] {
                    next = running + 1
                } else {
                    next = max(1, storedIndex)
                }
                counters[key] = next
                spec = BlockSpec(
                    kind: .orderedListItem(index: next),
                    blockquoteDepth: quoteDepth,
                    listLevel: listLevel
                )
            } else if spec.isListItem {
                // A bullet / task item at this level closes any ordered
                // list open there.
                counters[Key(level: listLevel, quote: quoteDepth)] = nil
                spec = BlockSpec(kind: spec.kind, blockquoteDepth: quoteDepth, listLevel: listLevel)
            } else {
                counters.removeAll()
                spec = BlockSpec(kind: spec.kind, blockquoteDepth: quoteDepth, listLevel: spec.listLevel)
            }

            // Anything nested deeper than this line is no longer open.
            counters = counters.filter { $0.key.level <= listLevel }

            out.append(spec)
            previousListLevel = spec.isListItem ? listLevel : nil
            previousQuoteDepth = quoteDepth
            cursor = line.location + line.length
        }
        return out
    }

    private struct Key: Hashable {
        let level: Int
        let quote: Int
    }
}
