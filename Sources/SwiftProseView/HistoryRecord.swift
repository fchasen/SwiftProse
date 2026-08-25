import Foundation

/// One undoable unit.
///
/// The inverse is a list of typed `Step`s in newest-first order, replayed
/// with `Transaction.apply(..., sequential: true)`. Because they are typed,
/// undo preserves `NodeID`s and identity-addressed steps
/// (`replaceCellInline`, `setTableSubtree`) reverse correctly — a text
/// snapshot of the mutated range cannot express either, which is why table
/// cell edits used to undo to nothing.
///
/// A reference type: a typing burst registers once and then grows in place
/// as later keystrokes join it, so the closure already on the `UndoManager`
/// sees the whole burst.
final class HistoryRecord {
    /// Newest first. Replayed in order, without mapping.
    var inverseSteps: [Step]
    /// Where the caret was before this unit; installed on undo.
    var selectionBefore: NSRange
    /// Where the caret ended up; installed on redo.
    var selectionAfter: NSRange
    /// Post-edit ranges this unit has touched. A new edit joins only if it
    /// abuts one of them — PM starts a fresh group for non-adjacent edits
    /// however fast you type.
    var touchedRanges: [NSRange]
    /// Timestamp of the most recent edit in the unit.
    var lastEditAt: TimeInterval
    var label: String?

    init(
        inverseSteps: [Step],
        selectionBefore: NSRange,
        selectionAfter: NSRange,
        touchedRanges: [NSRange],
        lastEditAt: TimeInterval,
        label: String? = nil
    ) {
        self.inverseSteps = inverseSteps
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.touchedRanges = touchedRanges
        self.lastEditAt = lastEditAt
        self.label = label
    }

    /// True when `range` abuts or overlaps something this unit has touched.
    func touches(_ range: NSRange) -> Bool {
        for touched in touchedRanges {
            let lo = touched.location
            let hi = touched.location + touched.length
            if range.location <= hi, range.location + range.length >= lo { return true }
        }
        return false
    }

    func absorb(
        inverseSteps newSteps: [Step],
        selectionAfter: NSRange,
        touched: NSRange,
        at time: TimeInterval
    ) {
        // Newest first: the joining edit is undone before everything
        // already in the unit.
        inverseSteps.insert(contentsOf: newSteps, at: 0)
        self.selectionAfter = selectionAfter
        touchedRanges.append(touched)
        lastEditAt = time
    }
}
