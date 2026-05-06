import Foundation

/// Compiled PM-style content expression. A sequence of `Element`s, each of
/// which accepts certain node types and is constrained by a quantifier
/// (`?`, `+`, `*`, or none for "exactly one"). Mirrors ProseMirror's
/// `ContentMatch` — though the public surface is intentionally minimal:
/// `matchType`, `validEnd`, `defaultType`, and `edgeCount` cover the use
/// cases the rest of SwiftProse needs.
///
/// An expression like `"paragraph block*"` parses into two elements: one
/// requiring exactly one `paragraph`, then one allowing zero-or-more nodes
/// from the `block` group. Group names are resolved against the supplied
/// `allowedNodes` set — the caller passes in the precomputed group
/// expansion so `ContentMatch` doesn't need a back-reference to `Schema`.
public struct ContentMatch: Sendable, Equatable, Hashable {

    public struct Element: Sendable, Equatable, Hashable {
        /// Names this slot accepts. Already resolved against group
        /// definitions (e.g. `"block"` → every block-group member).
        public let accepts: Set<String>
        /// Atomic source — preserved so `defaultType` can pick a sensible
        /// fill candidate. For an alternation the first listed atom wins.
        public let preferredFill: String?
        public let min: Int
        public let max: Int?

        /// Match-loop bookkeeping: whether a single atom of `accepts` must
        /// land here, regardless of greedy choices. PM uses this for
        /// "exactly one paragraph then any block".
        public var isRequired: Bool { min > 0 }
    }

    /// One position in the automaton. Compares by element index and the
    /// number of nodes consumed at that element.
    public struct State: Sendable, Equatable, Hashable {
        public let elementIndex: Int
        public let count: Int

        public init(elementIndex: Int = 0, count: Int = 0) {
            self.elementIndex = elementIndex
            self.count = count
        }
    }

    /// Original expression source — kept for diagnostics and for the
    /// codec round-trip via `ContentExpression.raw`.
    public let raw: String
    public let elements: [Element]

    /// Initial state — element 0, count 0.
    public var initialState: State { State() }

    /// Whether this expression accepts an empty sequence (validEnd at
    /// the initial state).
    public var validForEmpty: Bool { validEnd(at: initialState) }

    /// Try to consume one node of type `name`, returning the post-consume
    /// state or nil when the move is illegal.
    public func matchType(_ name: String, from state: State = State()) -> State? {
        var idx = state.elementIndex
        var count = state.count
        while idx < elements.count {
            let elem = elements[idx]
            if elem.accepts.contains(name) {
                if let max = elem.max, count + 1 > max {
                    // Hit the upper bound for this slot — advance past it.
                    idx += 1
                    count = 0
                    continue
                }
                return State(elementIndex: idx, count: count + 1)
            }
            // Can't match here. If this slot's lower bound is already met,
            // we can advance to the next element and try there.
            if count >= elem.min {
                idx += 1
                count = 0
                continue
            }
            return nil
        }
        return nil
    }

    /// Try to consume each name in `names` in order, returning the final
    /// state or nil when the sequence is illegal.
    public func matchFragment(_ names: [String], from state: State = State()) -> State? {
        var current = state
        for name in names {
            guard let next = matchType(name, from: current) else { return nil }
            current = next
        }
        return current
    }

    /// Whether `state` is an accepting state — every element from
    /// `elementIndex` onward has its lower bound already satisfied.
    public func validEnd(at state: State) -> Bool {
        guard state.elementIndex <= elements.count else { return false }
        if state.elementIndex < elements.count {
            let here = elements[state.elementIndex]
            if state.count < here.min { return false }
        }
        for i in (state.elementIndex + 1)..<elements.count {
            if elements[i].min > 0 { return false }
        }
        return true
    }

    /// Convenience: validate a full child sequence against the
    /// expression's start. Greedy / linear — adequate for the schema
    /// patterns SwiftProse declares.
    public func matches(_ names: [String]) -> Bool {
        guard let state = matchFragment(names) else { return false }
        return validEnd(at: state)
    }

    /// PM's "default child to insert when filling content". Picks the
    /// first required element's preferred fill name, or — if every slot
    /// is optional — nil.
    public func defaultType(at state: State = State()) -> String? {
        var idx = state.elementIndex
        var count = state.count
        while idx < elements.count {
            let elem = elements[idx]
            if count < elem.min, let fill = elem.preferredFill ?? elem.accepts.first {
                return fill
            }
            idx += 1
            count = 0
        }
        return nil
    }

    /// Number of distinct atom transitions out of `state`. PM uses this
    /// to disambiguate "the only legal child here is X" vs "many options".
    public func edgeCount(at state: State = State()) -> Int {
        guard state.elementIndex < elements.count else { return 0 }
        return elements[state.elementIndex].accepts.count
    }

    // MARK: - parsing

    /// Parse `raw` into a `ContentMatch`. `groupExpansions` maps
    /// group/atom names to their resolved acceptance sets — typically the
    /// same `allowedNodes` set the legacy `ContentExpression` API took.
    /// Returns nil for malformed input.
    public static func parse(
        _ raw: String,
        allowedNodes: Set<String>
    ) -> ContentMatch? {
        var parser = Parser(source: raw, allowedNodes: allowedNodes)
        guard let elems = parser.parseSequence(), parser.atEnd() else { return nil }
        return ContentMatch(raw: raw, elements: elems)
    }

    private struct Parser {
        let source: String
        let allowedNodes: Set<String>
        var index: String.Index

        init(source: String, allowedNodes: Set<String>) {
            self.source = source
            self.allowedNodes = allowedNodes
            self.index = source.startIndex
        }

        mutating func atEnd() -> Bool {
            skipWhitespace()
            return index == source.endIndex
        }

        mutating func skipWhitespace() {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
        }

        mutating func parseSequence() -> [Element]? {
            var elements: [Element] = []
            while true {
                skipWhitespace()
                guard index < source.endIndex else { break }
                guard let elem = parseElement() else { return nil }
                elements.append(elem)
            }
            return elements
        }

        mutating func parseElement() -> Element? {
            skipWhitespace()
            guard index < source.endIndex else { return nil }
            let (accepts, preferred): (Set<String>, String?)
            if source[index] == "(" {
                index = source.index(after: index)
                guard let alt = parseAlternation() else { return nil }
                skipWhitespace()
                guard index < source.endIndex, source[index] == ")" else { return nil }
                index = source.index(after: index)
                accepts = alt.accepts
                preferred = alt.preferred
            } else {
                guard let name = parseName() else { return nil }
                accepts = resolveName(name)
                preferred = accepts.contains(name) ? name : accepts.first
            }
            let quant = parseQuantifier()
            return Element(
                accepts: accepts,
                preferredFill: preferred,
                min: quant.min,
                max: quant.max
            )
        }

        mutating func parseAlternation() -> (accepts: Set<String>, preferred: String?)? {
            var accepts: Set<String> = []
            var preferred: String? = nil
            while true {
                skipWhitespace()
                guard let name = parseName() else { return nil }
                let resolved = resolveName(name)
                if preferred == nil { preferred = resolved.contains(name) ? name : resolved.first }
                accepts.formUnion(resolved)
                skipWhitespace()
                if index < source.endIndex, source[index] == "|" {
                    index = source.index(after: index)
                    continue
                }
                break
            }
            return (accepts, preferred)
        }

        mutating func parseName() -> String? {
            skipWhitespace()
            let start = index
            while index < source.endIndex,
                  source[index].isLetter || source[index].isNumber
                    || source[index] == "_" || source[index] == "-" {
                index = source.index(after: index)
            }
            guard start < index else { return nil }
            return String(source[start..<index])
        }

        mutating func parseQuantifier() -> (min: Int, max: Int?) {
            guard index < source.endIndex else { return (1, 1) }
            switch source[index] {
            case "+":
                index = source.index(after: index)
                return (1, nil)
            case "*":
                index = source.index(after: index)
                return (0, nil)
            case "?":
                index = source.index(after: index)
                return (0, 1)
            default:
                return (1, 1)
            }
        }

        /// Resolve a parsed atom name. Group references like `"block"` and
        /// `"inline"` are resolved to the caller-supplied `allowedNodes`
        /// set — the legacy `ContentExpression` callers were already passing
        /// in the expanded set, so we honor that contract. A bare node name
        /// (e.g. `"paragraph"`) resolves to itself when it appears in the
        /// allowed set; otherwise we treat it as a group token and broadcast
        /// to the full allowed set so old expressions keep working.
        func resolveName(_ name: String) -> Set<String> {
            if allowedNodes.contains(name) {
                return [name]
            }
            return allowedNodes
        }
    }
}
