import Foundation
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Stateless-between-evaluations matcher for input rules. Holds rules + a
/// single `isApplying` reentrancy guard; everything else (storage, cursor,
/// dispatch) is passed in per call so the runner stays unit-testable
/// without an `EditorController`.
public final class InputRuleRunner {
    public private(set) var rules: [InputRule]
    private(set) var isApplying: Bool = false

    public init(rules: [InputRule] = []) {
        self.rules = rules
    }

    public func register(_ rule: InputRule) {
        rules.append(rule)
    }

    /// Evaluate registered rules against the text from the start of the
    /// current paragraph up to `cursor`. If a rule matches with the cursor
    /// landing on the match's tail, dispatch its transaction via
    /// `apply` and return `true`. Returns `false` if no rule matches or if
    /// the runner is already applying a transaction (reentrancy guard).
    @discardableResult
    public func evaluate(
        storage: NSTextStorage,
        cursor: Int,
        env: StepEnvironment,
        apply: (Transaction) -> Void
    ) -> Bool {
        guard !isApplying else { return false }
        let total = storage.length
        guard cursor >= 0, cursor <= total else { return false }
        let ns = storage.string as NSString
        let lineRange = ns.paragraphRange(for: NSRange(location: max(0, min(cursor, max(0, total - 1))), length: 0))
        let prefixEnd = min(cursor, lineRange.location + lineRange.length)
        guard prefixEnd >= lineRange.location else { return false }
        let prefixRange = NSRange(location: lineRange.location, length: prefixEnd - lineRange.location)
        let prefix = ns.substring(with: prefixRange)
        let prefixNS = prefix as NSString
        let searchRange = NSRange(location: 0, length: prefixNS.length)

        for rule in rules {
            guard let match = rule.pattern.firstMatch(in: prefix, options: [], range: searchRange) else {
                continue
            }
            // Cursor must land at the end of the match. Without this anchor
            // a rule like `^# ` would fire on the first character of an
            // already-styled heading the user re-edits.
            guard match.range.location + match.range.length == prefixNS.length else {
                continue
            }
            let absoluteMatched = NSRange(
                location: prefixRange.location + match.range.location,
                length: match.range.length
            )
            var captures: [NSRange] = []
            captures.reserveCapacity(match.numberOfRanges)
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                if r.location == NSNotFound {
                    captures.append(r)
                } else {
                    captures.append(NSRange(
                        location: prefixRange.location + r.location,
                        length: r.length
                    ))
                }
            }
            let context = InputRule.Match(
                storage: storage,
                lineRange: lineRange,
                lineText: prefix,
                matchedRange: absoluteMatched,
                captureRanges: captures,
                cursor: cursor,
                env: env
            )
            guard let tx = rule.handler(context) else { continue }
            isApplying = true
            apply(tx)
            isApplying = false
            return true
        }
        return false
    }
}
