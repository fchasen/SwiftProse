import Foundation
import SwiftProseSyntax
import SwiftProseRendering
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
            var sawSpec = false
            var seenSpecs: [BlockSpec] = []
            for i in lineRange.location..<(lineRange.location + lineRange.length) {
                if let spec = storage.blockSpec(at: i) {
                    sawSpec = true
                    if !seenSpecs.contains(spec) { seenSpecs.append(spec) }
                } else {
                    out.append(SpecDiagnostic(issue: .missingSpec(at: i), lineRange: lineRange))
                }
            }
            if seenSpecs.count > 1 {
                out.append(SpecDiagnostic(issue: .inconsistentSpec(in: lineRange, found: seenSpecs), lineRange: lineRange))
            }
            // Marker / list-item alignment.
            if sawSpec, let canonical = seenSpecs.first, !canonical.isListItem {
                storage.enumerateAttribute(.proseListMarker, in: lineRange) { value, subRange, _ in
                    if (value as? Bool) == true {
                        for i in subRange.location..<(subRange.location + subRange.length) {
                            out.append(SpecDiagnostic(issue: .markerWithoutListItem(at: i), lineRange: lineRange))
                        }
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

    /// Pick the spec value the largest portion of the line agrees on.
    /// Returns nil if no character carries a spec.
    private static func canonicalSpec(
        in storage: NSAttributedString,
        lineRange: NSRange
    ) -> BlockSpec? {
        var counts: [BlockSpec: Int] = [:]
        storage.enumerateAttribute(.proseBlockSpec, in: lineRange) { value, subRange, _ in
            guard let spec = (value as? BlockSpecBox)?.spec else { return }
            counts[spec, default: 0] += subRange.length
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private static func applyCanonical(
        _ spec: BlockSpec,
        to storage: NSTextStorage,
        lineRange: NSRange
    ) {
        guard lineRange.length > 0,
              lineRange.location + lineRange.length <= storage.length else { return }
        storage.beginEditing()
        storage.addAttribute(.proseBlockSpec, value: BlockSpecBox(spec), range: lineRange)
        if !spec.isListItem {
            storage.removeAttribute(.proseListMarker, range: lineRange)
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
        let safe = range.clamped(to: ns.length)
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
