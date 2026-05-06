import Foundation
import SwiftProseSyntax

/// Native spell / grammar / autocorrect behavior for the editor's text view.
///
/// On macOS, code blocks and inline code spans are excluded from checking
/// automatically — the text-view coordinator implements
/// `textView(_:shouldCheckTextIn:offset:types:)` and clips the candidate
/// range using the canonical `proseNodePath` / `proseMarks` attributes.
///
/// On iOS, `UITextView` only exposes whole-view toggles
/// (`spellCheckingType`, `autocorrectionType`); per-range exclusion isn't
/// available, so fenced code may receive false positives when checking is on.
public enum ProseSpellChecking: Sendable, Equatable {
    /// No spell-check, no grammar-check, no autocorrect.
    case off
    /// Continuous spelling underlines. No grammar, no autocorrect.
    case spelling
    /// Spelling + grammar underlines. No autocorrect.
    case spellingAndGrammar
    /// Spelling + grammar + automatic spelling correction (autocorrect).
    case full

    public var spellingEnabled: Bool {
        switch self {
        case .off: return false
        case .spelling, .spellingAndGrammar, .full: return true
        }
    }

    public var grammarEnabled: Bool {
        switch self {
        case .off, .spelling: return false
        case .spellingAndGrammar, .full: return true
        }
    }

    public var autocorrectEnabled: Bool {
        switch self {
        case .off, .spelling, .spellingAndGrammar: return false
        case .full: return true
        }
    }
}

public extension ProseSpellChecking {
    /// First contiguous run inside `candidate` that shouldn't be skipped by
    /// the spell checker — i.e. that doesn't fall inside a fenced/indented
    /// code block or an inline `code` mark. Returns a zero-length range
    /// when the entire candidate is uncheckable.
    ///
    /// Used by the macOS coordinator's `shouldCheckTextIn` delegate hook.
    static func firstCheckableRange(
        in candidate: NSRange,
        storage: NSAttributedString
    ) -> NSRange {
        let total = storage.length
        let start = max(0, min(candidate.location, total))
        let bound = max(0, min(candidate.location + candidate.length, total))
        guard start < bound else {
            return NSRange(location: start, length: 0)
        }
        var i = start
        while i < bound, !isCheckable(at: i, in: storage) { i += 1 }
        let runStart = i
        while i < bound, isCheckable(at: i, in: storage) { i += 1 }
        return NSRange(location: runStart, length: i - runStart)
    }

    private static func isCheckable(
        at index: Int,
        in storage: NSAttributedString
    ) -> Bool {
        if storage.blockSpec(at: index)?.isCodeBlock == true { return false }
        if storage.markSet(at: index)?.contains(type: "code") == true { return false }
        return true
    }
}
