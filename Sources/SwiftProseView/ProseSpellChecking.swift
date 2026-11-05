import SwiftProseSyntax
import SwiftProseRendering
import Foundation

public enum ProseSpellChecking: Sendable, Equatable {
    case off
    case spelling
    case spellingAndGrammar
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

    public var withoutAutocorrection: ProseSpellChecking {
        self == .full ? .spellingAndGrammar : self
    }
}

public extension ProseSpellChecking {
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
        !storage.isMarkdownCode(at: index)
    }
}
