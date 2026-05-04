import Foundation

/// One inline annotation — bold, italic, code, link, etc. — as a value
/// rather than a rendering attribute. ProseMirror's terminology: marks
/// attach to text nodes; the same character can carry multiple marks.
///
/// Existing rendering attributes (`font` traits, `foregroundColor`,
/// `proseInline`, `proseLink`) become a projection of the canonical
/// `MarkSet`. Compiler / codec / commands read and write `MarkSet`; the
/// rendering attributes are derived in the layout layer.
public struct ProseMark: Sendable, Equatable, Hashable {
    public let type: MarkType.Name
    public let attrs: [String: ProseAttrValue]

    public init(type: MarkType.Name, attrs: [String: ProseAttrValue] = [:]) {
        self.type = type
        self.attrs = attrs
    }
}

/// Ordered, deduplicated collection of inline marks for a run of text. Two
/// marks of the same type can't coexist on the same character; adding a
/// new mark of an existing type replaces it (matches ProseMirror semantics
/// for distinct marks of the same kind, e.g. two `link` marks).
public struct MarkSet: Sendable, Equatable, Hashable {
    public let marks: [ProseMark]

    public init(_ marks: [ProseMark] = []) {
        var seen = Set<MarkType.Name>()
        var out: [ProseMark] = []
        out.reserveCapacity(marks.count)
        for mark in marks where !seen.contains(mark.type) {
            seen.insert(mark.type)
            out.append(mark)
        }
        self.marks = out
    }

    public var isEmpty: Bool { marks.isEmpty }

    public func contains(type: MarkType.Name) -> Bool {
        marks.contains { $0.type == type }
    }

    public func mark(of type: MarkType.Name) -> ProseMark? {
        marks.first { $0.type == type }
    }

    /// Add a mark, replacing any existing mark of the same type. Returns a
    /// new `MarkSet`. Without a schema, the new mark goes at the end —
    /// callers that care about rank ordering (codec emit, copy/paste,
    /// serialization stability) should use `adding(_:in:)`.
    public func adding(_ mark: ProseMark) -> MarkSet {
        var copy = marks.filter { $0.type != mark.type }
        copy.append(mark)
        return MarkSet(copy)
    }

    /// Add a mark, sorting the result by the schema's declared mark-type
    /// order (rank). Mirrors ProseMirror's `Mark.addToSet` ordering, which
    /// guarantees `[strong, em]` and `[em, strong]` always serialize the
    /// same way regardless of which mark was applied first.
    public func adding(_ mark: ProseMark, in schema: Schema) -> MarkSet {
        var working = marks.filter { $0.type != mark.type }
        working.append(mark)
        working.sort { schema.rank(ofMark: $0.type) < schema.rank(ofMark: $1.type) }
        return MarkSet(working)
    }

    public func removing(_ type: MarkType.Name) -> MarkSet {
        MarkSet(marks.filter { $0.type != type })
    }

    /// Union, with `other` winning when both sides hold a mark of the same
    /// type (so newer attribute values overwrite older). Order: `self` first,
    /// then `other` for marks not already present.
    public func merging(_ other: MarkSet) -> MarkSet {
        let mine = marks.filter { mark in !other.contains(type: mark.type) }
        return MarkSet(mine + other.marks)
    }
}

/// Reference-typed wrapper for `NSAttributedString` storage. Same rationale
/// as `NodePathBox` / `BlockSpecBox` — reference identity keeps adjacent
/// attribute runs separable even when their value-equal mark sets would
/// otherwise collapse into one run.
public final class MarkSetBox: NSObject, @unchecked Sendable {
    public let marks: MarkSet

    public init(_ marks: MarkSet) {
        self.marks = marks
        super.init()
    }
}

public extension NSAttributedString {
    func markSet(at index: Int) -> MarkSet? {
        guard index >= 0, index < length else { return nil }
        let raw = attribute(.proseMarks, at: index, effectiveRange: nil)
        return (raw as? MarkSetBox)?.marks
    }

    func enumerateMarkSets(
        in range: NSRange? = nil,
        _ body: (NSRange, MarkSet) -> Void
    ) {
        let scan = range ?? NSRange(location: 0, length: length)
        guard scan.length > 0 else { return }
        enumerateAttribute(.proseMarks, in: scan) { value, subRange, _ in
            if let box = value as? MarkSetBox {
                body(subRange, box.marks)
            }
        }
    }
}

public extension NSMutableAttributedString {
    func setMarkSet(_ marks: MarkSet, in range: NSRange) {
        guard range.length > 0,
              range.location >= 0,
              range.location + range.length <= length else { return }
        if marks.isEmpty {
            removeAttribute(.proseMarks, range: range)
        } else {
            addAttribute(.proseMarks, value: MarkSetBox(marks), range: range)
        }
    }
}
