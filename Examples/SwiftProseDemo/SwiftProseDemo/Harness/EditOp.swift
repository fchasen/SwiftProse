import Foundation

/// A position in the document. `at` is a raw UTF-16 storage offset; the
/// anchor fields resolve against the storage string and win when they
/// match, so a shrunk op log stays meaningful after the ops that produced
/// the offsets around it were dropped.
struct Anchor: Codable, Equatable {
    enum Edge: String, Codable { case start, end }

    /// Raw UTF-16 offset. Clamped into the document.
    var at: Int?
    /// Land immediately before the `n`th occurrence of this substring.
    var before: String?
    /// Land immediately after the `n`th occurrence of this substring.
    var after: String?
    /// Occurrence index for `before` / `after`. 0-based.
    var n: Int = 0
    /// 0-based index of a top-level block, paired with `edge`.
    var block: Int?
    var edge: Edge?

    init(at: Int? = nil,
         before: String? = nil,
         after: String? = nil,
         n: Int = 0,
         block: Int? = nil,
         edge: Edge? = nil) {
        self.at = at
        self.before = before
        self.after = after
        self.n = n
        self.block = block
        self.edge = edge
    }

    static func offset(_ value: Int) -> Anchor { Anchor(at: value) }

    // Written by hand so `n` may be omitted: synthesized Decodable ignores
    // property defaults and would throw `keyNotFound` on every anchor.
    private enum K: String, CodingKey { case at, before, after, n, block, edge }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        at = try c.decodeIfPresent(Int.self, forKey: .at)
        before = try c.decodeIfPresent(String.self, forKey: .before)
        after = try c.decodeIfPresent(String.self, forKey: .after)
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 0
        block = try c.decodeIfPresent(Int.self, forKey: .block)
        edge = try c.decodeIfPresent(Edge.self, forKey: .edge)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(at, forKey: .at)
        try c.encodeIfPresent(before, forKey: .before)
        try c.encodeIfPresent(after, forKey: .after)
        if n != 0 { try c.encode(n, forKey: .n) }
        try c.encodeIfPresent(block, forKey: .block)
        try c.encodeIfPresent(edge, forKey: .edge)
    }

    /// Resolve against a storage string. Returns nil only when an anchor
    /// substring is present and doesn't occur `n + 1` times — the caller
    /// decides whether that is a failure or a skip.
    func resolve(in string: NSString) -> Int? {
        if let needle = before ?? after {
            guard let found = Self.occurrence(of: needle, n: n, in: string) else { return nil }
            return before != nil ? found.location : found.location + found.length
        }
        if let block, let edge {
            let lines = Self.topLevelBlockRanges(in: string)
            guard block >= 0, block < lines.count else { return nil }
            let r = lines[block]
            return edge == .start ? r.location : r.location + r.length
        }
        guard let at else { return nil }
        return max(0, min(at, string.length))
    }

    private static func occurrence(of needle: String, n: Int, in string: NSString) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        var searchFrom = 0
        var seen = 0
        while searchFrom <= string.length {
            let remaining = NSRange(location: searchFrom, length: string.length - searchFrom)
            let found = string.range(of: needle, options: [], range: remaining)
            if found.location == NSNotFound { return nil }
            if seen == n { return found }
            seen += 1
            searchFrom = found.location + max(1, found.length)
        }
        return nil
    }

    /// Blank-line-separated blocks, as the fuzzer and the doc shrinker see
    /// them. Cheap and string-local — deliberately not the projected tree.
    static func topLevelBlockRanges(in string: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        var i = 0
        while i < string.length {
            let lineRange = string.lineRange(for: NSRange(location: i, length: 0))
            let line = string.substring(with: lineRange)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if lineRange.location > start {
                    out.append(NSRange(location: start, length: lineRange.location - start))
                }
                start = lineRange.location + lineRange.length
            }
            i = lineRange.location + max(1, lineRange.length)
        }
        if start < string.length {
            out.append(NSRange(location: start, length: string.length - start))
        }
        return out
    }
}

/// What a scenario asserts after its ops have run.
struct Expectation: Codable, Equatable {
    /// Markdown with optional `<|>` / `<{`…`}>` selection markers.
    var doc: String?
    /// Raw selection, when the doc string can't carry a marker.
    var selection: [Int]?
    /// `BlockSpec.kind` description at the caret.
    var blockKind: String?
    var canUndo: Bool?
    var canRedo: Bool?
    /// Mark names active at the caret, sorted.
    var marks: [String]?
    /// Undo depth after the ops.
    var undoDepth: Int?
}

/// The op vocabulary a scenario file or fuzz log is written in.
///
/// Foundation only — this file is also a member of the out-of-process
/// UITests bundle, which can't import the app.
enum EditOp: Equatable {
    /// Per-character `insertText`, the path `NSTextInputContext` uses.
    case type(text: String)
    /// One `insertText` of the whole string — the dictation / bulk route.
    case typeBurst(text: String)
    /// A named key. See `EditDriver.KeyTable` for the vocabulary.
    case key(String)
    case undo(n: Int)
    case redo(n: Int)
    case selectAll
    case copy
    case cut
    case paste(text: String, html: String?, plain: Bool)
    case caret(Anchor)
    case select(from: Anchor, to: Anchor)
    case action(id: String, url: String?, label: String?, rows: Int?, columns: Int?)
    /// IME: marked-text interims, then a commit (nil unmarks — a cancel).
    case compose(interims: [String], commit: String?)
    /// Autocorrect shape: replace a range the selection is not on.
    case correct(find: String, replace: String)
    case toggleCheckbox(Anchor)
    case load(markdown: String, keepHistory: Bool)
    case closeHistoryGroup
    case wait(ms: Int)
    case expect(Expectation)
    case check(oracles: [String])
}

// MARK: - Codable

extension EditOp: Codable {
    private enum K: String, CodingKey {
        case op, text, html, plain, key, n, at, before, after, block, edge
        case from, to, id, url, label, rows, columns, interims, commit
        case find, replace, markdown, keepHistory, ms, oracles, length
        case doc, selection, blockKind, canUndo, canRedo, marks, undoDepth
    }

    /// Anchors are written inline on the op object (`{"op":"caret","at":5}`)
    /// rather than nested, because that is what a fuzz log is easiest to
    /// read and hand-edit as.
    private static func anchor(from c: KeyedDecodingContainer<K>) throws -> Anchor {
        Anchor(
            at: try c.decodeIfPresent(Int.self, forKey: .at),
            before: try c.decodeIfPresent(String.self, forKey: .before),
            after: try c.decodeIfPresent(String.self, forKey: .after),
            n: try c.decodeIfPresent(Int.self, forKey: .n) ?? 0,
            block: try c.decodeIfPresent(Int.self, forKey: .block),
            edge: try c.decodeIfPresent(Anchor.Edge.self, forKey: .edge)
        )
    }

    private static func encode(_ a: Anchor, into c: inout KeyedEncodingContainer<K>) throws {
        try c.encodeIfPresent(a.at, forKey: .at)
        try c.encodeIfPresent(a.before, forKey: .before)
        try c.encodeIfPresent(a.after, forKey: .after)
        if a.n != 0 { try c.encode(a.n, forKey: .n) }
        try c.encodeIfPresent(a.block, forKey: .block)
        try c.encodeIfPresent(a.edge, forKey: .edge)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "type":
            self = .type(text: try c.decode(String.self, forKey: .text))
        case "typeBurst":
            self = .typeBurst(text: try c.decode(String.self, forKey: .text))
        case "key":
            self = .key(try c.decode(String.self, forKey: .key))
        case "undo":
            self = .undo(n: try c.decodeIfPresent(Int.self, forKey: .n) ?? 1)
        case "redo":
            self = .redo(n: try c.decodeIfPresent(Int.self, forKey: .n) ?? 1)
        case "selectAll":
            self = .selectAll
        case "copy":
            self = .copy
        case "cut":
            self = .cut
        case "paste":
            self = .paste(
                text: try c.decode(String.self, forKey: .text),
                html: try c.decodeIfPresent(String.self, forKey: .html),
                plain: try c.decodeIfPresent(Bool.self, forKey: .plain) ?? true
            )
        case "caret":
            self = .caret(try Self.anchor(from: c))
        case "select":
            // Either `from` / `to` anchors, or an inline `at` + `length`.
            if let from = try c.decodeIfPresent(Anchor.self, forKey: .from) {
                self = .select(from: from, to: try c.decode(Anchor.self, forKey: .to))
            } else {
                let start = try Self.anchor(from: c)
                let length = try c.decodeIfPresent(Int.self, forKey: .length) ?? 0
                self = .select(from: start, to: Anchor(at: (start.at ?? 0) + length))
            }
        case "action":
            self = .action(
                id: try c.decode(String.self, forKey: .id),
                url: try c.decodeIfPresent(String.self, forKey: .url),
                label: try c.decodeIfPresent(String.self, forKey: .label),
                rows: try c.decodeIfPresent(Int.self, forKey: .rows),
                columns: try c.decodeIfPresent(Int.self, forKey: .columns)
            )
        case "compose":
            self = .compose(
                interims: try c.decode([String].self, forKey: .interims),
                commit: try c.decodeIfPresent(String.self, forKey: .commit)
            )
        case "correct":
            self = .correct(
                find: try c.decode(String.self, forKey: .find),
                replace: try c.decode(String.self, forKey: .replace)
            )
        case "toggleCheckbox":
            self = .toggleCheckbox(try Self.anchor(from: c))
        case "load":
            self = .load(
                markdown: try c.decode(String.self, forKey: .markdown),
                keepHistory: try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? false
            )
        case "closeHistoryGroup":
            self = .closeHistoryGroup
        case "wait":
            self = .wait(ms: try c.decodeIfPresent(Int.self, forKey: .ms) ?? 0)
        case "expect":
            self = .expect(Expectation(
                doc: try c.decodeIfPresent(String.self, forKey: .doc),
                selection: try c.decodeIfPresent([Int].self, forKey: .selection),
                blockKind: try c.decodeIfPresent(String.self, forKey: .blockKind),
                canUndo: try c.decodeIfPresent(Bool.self, forKey: .canUndo),
                canRedo: try c.decodeIfPresent(Bool.self, forKey: .canRedo),
                marks: try c.decodeIfPresent([String].self, forKey: .marks),
                undoDepth: try c.decodeIfPresent(Int.self, forKey: .undoDepth)
            ))
        case "check":
            self = .check(oracles: try c.decode([String].self, forKey: .oracles))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: c, debugDescription: "unknown op \"\(op)\""
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .type(let text):
            try c.encode("type", forKey: .op); try c.encode(text, forKey: .text)
        case .typeBurst(let text):
            try c.encode("typeBurst", forKey: .op); try c.encode(text, forKey: .text)
        case .key(let key):
            try c.encode("key", forKey: .op); try c.encode(key, forKey: .key)
        case .undo(let n):
            try c.encode("undo", forKey: .op); try c.encode(n, forKey: .n)
        case .redo(let n):
            try c.encode("redo", forKey: .op); try c.encode(n, forKey: .n)
        case .selectAll:
            try c.encode("selectAll", forKey: .op)
        case .copy:
            try c.encode("copy", forKey: .op)
        case .cut:
            try c.encode("cut", forKey: .op)
        case .paste(let text, let html, let plain):
            try c.encode("paste", forKey: .op)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(html, forKey: .html)
            try c.encode(plain, forKey: .plain)
        case .caret(let a):
            try c.encode("caret", forKey: .op); try Self.encode(a, into: &c)
        case .select(let from, let to):
            try c.encode("select", forKey: .op)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case .action(let id, let url, let label, let rows, let columns):
            try c.encode("action", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encodeIfPresent(label, forKey: .label)
            try c.encodeIfPresent(rows, forKey: .rows)
            try c.encodeIfPresent(columns, forKey: .columns)
        case .compose(let interims, let commit):
            try c.encode("compose", forKey: .op)
            try c.encode(interims, forKey: .interims)
            try c.encodeIfPresent(commit, forKey: .commit)
        case .correct(let find, let replace):
            try c.encode("correct", forKey: .op)
            try c.encode(find, forKey: .find)
            try c.encode(replace, forKey: .replace)
        case .toggleCheckbox(let a):
            try c.encode("toggleCheckbox", forKey: .op); try Self.encode(a, into: &c)
        case .load(let markdown, let keepHistory):
            try c.encode("load", forKey: .op)
            try c.encode(markdown, forKey: .markdown)
            if keepHistory { try c.encode(true, forKey: .keepHistory) }
        case .closeHistoryGroup:
            try c.encode("closeHistoryGroup", forKey: .op)
        case .wait(let ms):
            try c.encode("wait", forKey: .op); try c.encode(ms, forKey: .ms)
        case .expect(let e):
            try c.encode("expect", forKey: .op)
            try c.encodeIfPresent(e.doc, forKey: .doc)
            try c.encodeIfPresent(e.selection, forKey: .selection)
            try c.encodeIfPresent(e.blockKind, forKey: .blockKind)
            try c.encodeIfPresent(e.canUndo, forKey: .canUndo)
            try c.encodeIfPresent(e.canRedo, forKey: .canRedo)
            try c.encodeIfPresent(e.marks, forKey: .marks)
            try c.encodeIfPresent(e.undoDepth, forKey: .undoDepth)
        case .check(let oracles):
            try c.encode("check", forKey: .op); try c.encode(oracles, forKey: .oracles)
        }
    }
}

extension EditOp {
    /// One-line form for op logs and failure messages.
    var summary: String {
        switch self {
        case .type(let t): return "type \(Self.quote(t))"
        case .typeBurst(let t): return "typeBurst \(Self.quote(t))"
        case .key(let k): return "key \(k)"
        case .undo(let n): return "undo \(n)"
        case .redo(let n): return "redo \(n)"
        case .selectAll: return "selectAll"
        case .copy: return "copy"
        case .cut: return "cut"
        case .paste(let t, let h, let p):
            return "paste\(p ? "" : " rich")\(h == nil ? "" : "+html") \(Self.quote(t))"
        case .caret(let a): return "caret \(a.summary)"
        case .select(let f, let t): return "select \(f.summary)…\(t.summary)"
        case .action(let id, _, _, _, _): return "action \(id)"
        case .compose(let i, let c):
            return "compose \(i.map(Self.quote).joined(separator: "→"))⇒\(c.map(Self.quote) ?? "cancel")"
        case .correct(let f, let r): return "correct \(Self.quote(f))→\(Self.quote(r))"
        case .toggleCheckbox(let a): return "toggleCheckbox \(a.summary)"
        case .load: return "load"
        case .closeHistoryGroup: return "closeHistoryGroup"
        case .wait(let ms): return "wait \(ms)ms"
        case .expect: return "expect"
        case .check(let o): return "check \(o.joined(separator: ","))"
        }
    }

    /// Ops that don't mutate the document. The shrinker keeps these only
    /// when something after them still needs them.
    var isReadOnly: Bool {
        switch self {
        case .caret, .select, .selectAll, .copy, .wait, .expect, .check,
             .closeHistoryGroup:
            return true
        default:
            return false
        }
    }

    static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped.count > 40 ? String(escaped.prefix(40)) + "…" : escaped)\""
    }
}

extension Anchor {
    var summary: String {
        if let before { return "before(\(EditOp.quote(before))#\(n))" }
        if let after { return "after(\(EditOp.quote(after))#\(n))" }
        if let block, let edge { return "block\(block).\(edge.rawValue)" }
        return "\(at ?? 0)"
    }
}

// MARK: - JSONL

enum OpLog {
    static func encode(_ ops: [EditOp]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try ops.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
    }

    static func decode(_ text: String) throws -> [EditOp] {
        let decoder = JSONDecoder()
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(EditOp.self, from: Data($0.utf8)) }
    }
}
