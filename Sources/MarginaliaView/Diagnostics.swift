import Foundation
import MarginaliaSyntax
import MarginaliaRendering
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct SpecDiagnostic: Equatable, Sendable {
    public let issue: Issue
    public let lineRange: NSRange

    public enum Issue: Equatable, Sendable {
        case missingSpec(at: Int)
        case inconsistentSpec(in: NSRange, found: [BlockSpec])
        case markerWithoutListItem(at: Int)
        case listItemWithoutMarker(in: NSRange)
    }
}

public enum SpecValidator {

    /// Walk every paragraph that intersects `range` and report invariant
    /// violations: every char must carry a spec, all chars in a paragraph
    /// must agree on the spec, marker-flagged chars must align with a
    /// list-item paragraph.
    public static func validate(
        in storage: NSAttributedString,
        range: NSRange
    ) -> [SpecDiagnostic] {
        var out: [SpecDiagnostic] = []
        forEachLine(in: storage, range: range) { lineRange in
            // Missing spec.
            var sawSpec = false
            for i in lineRange.location..<(lineRange.location + lineRange.length) {
                if storage.blockSpec(at: i) == nil {
                    out.append(SpecDiagnostic(issue: .missingSpec(at: i), lineRange: lineRange))
                } else {
                    sawSpec = true
                }
            }
            // Inconsistent specs.
            var seenSpecs: [BlockSpec] = []
            for i in lineRange.location..<(lineRange.location + lineRange.length) {
                if let spec = storage.blockSpec(at: i), !seenSpecs.contains(spec) {
                    seenSpecs.append(spec)
                }
            }
            if seenSpecs.count > 1 {
                out.append(SpecDiagnostic(issue: .inconsistentSpec(in: lineRange, found: seenSpecs), lineRange: lineRange))
            }
            // Marker / list-item alignment.
            if sawSpec, let canonical = seenSpecs.first {
                for i in lineRange.location..<(lineRange.location + lineRange.length) {
                    let marker = (storage.attribute(.marginaliaListMarker, at: i, effectiveRange: nil) as? Bool) == true
                    if marker && !canonical.isListItem {
                        out.append(SpecDiagnostic(issue: .markerWithoutListItem(at: i), lineRange: lineRange))
                    }
                }
            }
        }
        return out
    }

    /// Restore invariants by enforcing the most common BlockSpec across
    /// each paragraph (or `paragraph` if none is present), and stripping
    /// marker flags off chars whose paragraph isn't a list item.
    public static func repair(
        in storage: NSTextStorage,
        range: NSRange
    ) {
        forEachLine(in: storage, range: range) { lineRange in
            let canonical = canonicalSpec(in: storage, lineRange: lineRange) ?? .paragraph
            applyCanonical(canonical, to: storage, lineRange: lineRange)
        }
    }

    /// Pick the spec value that the largest contiguous run agrees on.
    /// Falls back to the first spec found, or nil if no chars carry one.
    private static func canonicalSpec(
        in storage: NSAttributedString,
        lineRange: NSRange
    ) -> BlockSpec? {
        var counts: [(BlockSpec, Int)] = []
        for i in lineRange.location..<(lineRange.location + lineRange.length) {
            guard let spec = storage.blockSpec(at: i) else { continue }
            if let idx = counts.firstIndex(where: { $0.0 == spec }) {
                counts[idx].1 += 1
            } else {
                counts.append((spec, 1))
            }
        }
        return counts.max(by: { $0.1 < $1.1 })?.0
    }

    private static func applyCanonical(
        _ spec: BlockSpec,
        to storage: NSTextStorage,
        lineRange: NSRange
    ) {
        guard lineRange.length > 0,
              lineRange.location + lineRange.length <= storage.length else { return }
        storage.beginEditing()
        storage.addAttribute(.marginaliaBlockSpec, value: BlockSpecBox(spec), range: lineRange)
        if !spec.isListItem {
            storage.removeAttribute(.marginaliaListMarker, range: lineRange)
        }
        storage.endEditing()
    }

    private static func forEachLine(
        in storage: NSAttributedString,
        range: NSRange,
        _ body: (NSRange) -> Void
    ) {
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString
        let safe = NSRange(
            location: max(0, min(range.location, ns.length)),
            length: max(0, min(range.length, ns.length - max(0, min(range.location, ns.length))))
        )
        // A zero-length range pins to the single paragraph containing the
        // location; without this guard the loop would walk every paragraph
        // until end-of-storage.
        let inclusiveEnd: Int
        if safe.length == 0 {
            inclusiveEnd = safe.location
        } else {
            inclusiveEnd = safe.location + safe.length - 1
        }
        var cursor = safe.location
        while cursor < ns.length {
            let line = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            body(line)
            let next = line.location + line.length
            if next == cursor { break }
            cursor = next
            if cursor > inclusiveEnd { break }
        }
    }
}
