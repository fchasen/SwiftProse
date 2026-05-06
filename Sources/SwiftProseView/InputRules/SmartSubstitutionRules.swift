import Foundation
import SwiftProseSyntax
#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Optional substitution rules — straight quotes → curly, `--` → em-dash,
/// `...` → ellipsis. Off by default; opt in via `RuleOptions.smartTypography`
/// when constructing the rule set.
public struct RuleOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let smartQuotes = RuleOptions(rawValue: 1 << 0)
    public static let ellipsis = RuleOptions(rawValue: 1 << 1)
    public static let emDash = RuleOptions(rawValue: 1 << 2)

    public static let smartTypography: RuleOptions = [.smartQuotes, .ellipsis, .emDash]
}

extension InputRule {

    /// Rules that swap typographic punctuation as the user types.
    /// Each is `inCode: .skip` — code spans / blocks shouldn't curl quotes.
    public static func smartSubstitutionRules(_ options: RuleOptions) -> [InputRule] {
        var rules: [InputRule] = []
        if options.contains(.smartQuotes) {
            rules.append(InputRule(
                id: "inputRule.openSingleQuote",
                pattern: "(^|[\\s\\(\\[\\{])'$",
                inCode: .skip
            ) { match in
                replaceTail(match, with: "\u{2018}", trailingChars: 1)
            })
            rules.append(InputRule(
                id: "inputRule.closeSingleQuote",
                pattern: "[^\\s\\(\\[\\{]'$",
                inCode: .skip
            ) { match in
                replaceTail(match, with: "\u{2019}", trailingChars: 1)
            })
            rules.append(InputRule(
                id: "inputRule.openDoubleQuote",
                pattern: "(^|[\\s\\(\\[\\{])\"$",
                inCode: .skip
            ) { match in
                replaceTail(match, with: "\u{201C}", trailingChars: 1)
            })
            rules.append(InputRule(
                id: "inputRule.closeDoubleQuote",
                pattern: "[^\\s\\(\\[\\{]\"$",
                inCode: .skip
            ) { match in
                replaceTail(match, with: "\u{201D}", trailingChars: 1)
            })
        }
        if options.contains(.ellipsis) {
            rules.append(InputRule(
                id: "inputRule.ellipsis",
                pattern: "\\.\\.\\.$",
                inCode: .skip
            ) { match in
                replaceTail(match, with: "\u{2026}", trailingChars: 3)
            })
        }
        if options.contains(.emDash) {
            rules.append(InputRule(
                id: "inputRule.emDash",
                pattern: "--$",
                inCode: .skip
            ) { match in
                replaceTail(match, with: "\u{2014}", trailingChars: 2)
            })
        }
        return rules
    }

    /// Replace the last `trailingChars` characters of `match.matchedRange`
    /// with `replacement`, preserving the rendering attributes of the
    /// character just before the substitution so the replacement inherits
    /// the surrounding font / marks.
    private static func replaceTail(
        _ match: InputRule.Match,
        with replacement: String,
        trailingChars: Int
    ) -> Transaction? {
        let matchedEnd = match.matchedRange.location + match.matchedRange.length
        guard matchedEnd >= trailingChars else { return nil }
        let replaceStart = matchedEnd - trailingChars
        let probe = max(0, replaceStart - 1)
        let attrs: [NSAttributedString.Key: Any]
        if probe < match.storage.length {
            attrs = match.storage.attributes(at: probe, effectiveRange: nil)
        } else {
            attrs = [:]
        }
        let replacementAttr = NSAttributedString(string: replacement, attributes: attrs)
        return Transaction(steps: [
            .replaceText(
                range: NSRange(location: replaceStart, length: trailingChars),
                with: replacementAttr
            )
        ], label: "Smart Substitution")
    }
}
