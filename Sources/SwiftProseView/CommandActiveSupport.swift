import Foundation
import SwiftProseSyntax

extension InlineMark {
    /// Schema mark name corresponding to this `InlineMark`. Mirrors the
    /// PM-basic naming.
    var markName: MarkType.Name {
        switch self {
        case .bold: return "strong"
        case .italic: return "em"
        case .strikethrough: return "strike"
        case .codeSpan: return "code"
        }
    }
}

extension NSAttributedString {
    /// Marks present at every character in `range`. nil if `range` is
    /// empty or out of bounds; an empty `MarkSet` if marks differ.
    func marksIntersected(in range: NSRange) -> MarkSet? {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= length
        else { return nil }
        var iterator = MarkIntersection()
        enumerateAttribute(.proseMarks, in: range) { value, _, _ in
            let marks = (value as? MarkSetBox)?.marks ?? MarkSet()
            iterator.observe(marks)
        }
        return iterator.result
    }
}

private struct MarkIntersection {
    private var current: MarkSet?

    mutating func observe(_ marks: MarkSet) {
        if let existing = current {
            current = MarkSet(existing.marks.filter { mark in
                marks.contains(name: mark.type)
            })
        } else {
            current = marks
        }
    }

    var result: MarkSet { current ?? MarkSet() }
}

extension MarkSet {
    public func contains(name: MarkType.Name) -> Bool {
        marks.contains(where: { $0.type == name })
    }
}

extension EditorController {
    /// True if `mark` should currently render as active given the
    /// selection: empty selection looks at stored inline marks plus the
    /// preceding character; non-empty looks at the intersection across the
    /// selection. Public so custom commands can reuse the same probe.
    public func inlineMarkIsActive(_ mark: InlineMark, selection: NSRange) -> Bool {
        let storage = textStorage
        if selection.length == 0 {
            // Stored marks only "light up" while the cursor is still at
            // the anchor — moving the cursor elsewhere drops them.
            if storedMarksAnchor == selection.location,
               storedInlineMarks.contains(mark) { return true }
            // Probe the character left of the cursor; PM treats marks at
            // cursor−1 as the "active" set for an empty selection because
            // typing extends them.
            let probe = selection.location - 1
            guard probe >= 0, probe < storage.length else { return false }
            let marks = storage.markSet(at: probe) ?? MarkSet()
            return marks.contains(name: mark.markName)
        }
        guard let intersection = storage.marksIntersected(in: selection) else {
            return false
        }
        return intersection.contains(name: mark.markName)
    }
}
