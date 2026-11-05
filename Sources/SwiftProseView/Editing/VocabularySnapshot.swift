import SwiftProseSyntax
import SwiftProseRendering
import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct VocabularySnapshot {
    static let keys: [NSAttributedString.Key] = [.markdownBlock, .markdownInlineIntent, .link, .markdownLiteral, .markdownTableSeparator]

    let range: NSRange
    private let runs: [(range: NSRange, values: [NSAttributedString.Key: Any])]

    init(capturing storage: NSAttributedString, in range: NSRange) {
        let clamped = Normalizer.clamp(range, to: storage.length)
        self.range = clamped
        var runs: [(range: NSRange, values: [NSAttributedString.Key: Any])] = []
        if clamped.length > 0 {
            storage.enumerateAttributes(in: clamped) { attributes, run, _ in
                var values: [NSAttributedString.Key: Any] = [:]
                for key in Self.keys {
                    if let value = attributes[key] { values[key] = value }
                }
                if let last = runs.last, NSMaxRange(last.range) == run.location,
                   NSDictionary(dictionary: last.values).isEqual(to: values) {
                    runs[runs.count - 1].range.length += run.length
                } else {
                    runs.append((run, values))
                }
            }
        }
        self.runs = runs
    }

    func matches(_ storage: NSAttributedString) -> Bool {
        guard NSMaxRange(range) <= storage.length else { return false }
        let current = VocabularySnapshot(capturing: storage, in: range)
        guard current.runs.count == runs.count else { return false }
        for (lhs, rhs) in zip(runs, current.runs) {
            guard NSEqualRanges(lhs.range, rhs.range),
                  NSDictionary(dictionary: lhs.values).isEqual(to: rhs.values) else { return false }
        }
        return true
    }

    func apply(to storage: NSMutableAttributedString) {
        guard NSMaxRange(range) <= storage.length else { return }
        for key in Self.keys { storage.removeAttribute(key, range: range) }
        for run in runs where !run.values.isEmpty {
            storage.addAttributes(run.values, range: run.range)
        }
    }

    func registerUndo(on manager: UndoManager, storage: NSMutableAttributedString) {
        guard manager.isUndoRegistrationEnabled,
              manager.groupsByEvent || manager.groupingLevel > 0 else { return }
        register(on: manager, storage: storage)
    }

    private func register(on manager: UndoManager, storage: NSMutableAttributedString) {
        manager.registerUndo(withTarget: storage) { [weak manager] target in
            guard let manager else { return }
            let inverse = VocabularySnapshot(capturing: target, in: range)
            let opensGroup = manager.groupingLevel == 0
            if opensGroup { manager.beginUndoGrouping() }
            inverse.register(on: manager, storage: target)
            if opensGroup { manager.endUndoGrouping() }
            target.beginEditing()
            apply(to: target)
            target.endEditing()
        }
    }
}

struct NormalizationResult {
    var touched: NSRange
    var revert: VocabularySnapshot?
}
