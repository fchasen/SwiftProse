import Foundation

/// A scripted edit scenario. Foundation only — dual-membered into the
/// out-of-process UITests bundle.
///
/// ```json
/// { "name": "lists/tab-indents-nested-item", "tags": ["lists", "ui"],
///   "doc": "- one\n- tw<|>o\n",
///   "ops": [ { "op": "key", "key": "Tab" } ],
///   "expect": { "doc": "- one\n  - tw<|>o\n" },
///   "finally": ["tier0", "projection"] }
/// ```
struct Scenario: Codable, Equatable {
    /// Path-like id: `category/slug`. Drives the generated XCTest name.
    var name: String
    var tags: [String] = []
    var config: Config?
    /// Initial markdown, with selection markers.
    var doc: String
    var ops: [EditOp] = []
    /// What the author believes should happen, in prose. The recorder
    /// prints it beside the observed result, so a scenario whose `expect`
    /// disagrees with the editor is triaged rather than silently rewritten.
    var intent: String?
    var expect: Expectation?
    /// Oracles to run once at the end, on top of the always-on tier 0.
    var finally: [String] = []
    /// Non-nil marks a known-failing scenario: the runner asserts it still
    /// fails and reports a green test, so a fix trips the xfail instead.
    var xfail: String?
    /// Non-nil marks a scenario that *traps*. An Objective-C exception
    /// cannot be caught in Swift, so the in-process runner would go down
    /// with it and take the rest of the suite. `ScenarioTests` skips these
    /// with the reason; `--harness replay` still runs them, which is how
    /// they were shrunk in the first place.
    var crashes: String?
    /// Per-file marker override, for docs whose content contains `<|>`.
    var markers: Markers?

    struct Config: Codable, Equatable {
        /// Seconds. Default `1e9` — grouping then depends only on explicit
        /// `closeHistoryGroup` ops and range adjacency.
        var newGroupDelay: Double?
        var depth: Int?
        /// Turn the DEBUG spec assertion off for a scenario that expects
        /// diagnostics.
        var assertsOnDiagnostics: Bool?
        var useStructuredBulkInsert: Bool?
    }

    struct Markers: Codable, Equatable {
        var caret: String
        var selectionStart: String
        var selectionEnd: String
    }

    static let defaultMarkers = Markers(
        caret: "<|>", selectionStart: "<{", selectionEnd: "}>"
    )

    var effectiveMarkers: Markers { markers ?? Self.defaultMarkers }

    /// Category segment of `name` — the ScenarioTests grouping.
    var category: String {
        name.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// `test_lists_tab_indents_nested_item`
    var testMethodName: String {
        var out = "test_"
        for ch in name {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if out.last != "_" { out.append("_") }
        }
        return out
    }
}

/// A markdown string with selection markers stripped, plus where they were.
///
/// Marker offsets are **not** storage offsets: `<|>` sits in the source
/// text, and compiling that source moves everything after it by however
/// many characters the presentation markers add. `ScenarioRunner` recovers
/// the real offsets with a sentinel compile; this type only does the
/// string-level bookkeeping the UITests bundle can also do.
struct MarkedText: Equatable {
    /// Source with the markers removed.
    var clean: String
    /// UTF-16 offsets into `clean` where the markers were.
    var caret: Int?
    var selectionStart: Int?
    var selectionEnd: Int?

    var hasSelection: Bool { selectionStart != nil && selectionEnd != nil }

    enum Failure: Error, CustomStringConvertible {
        case unbalancedSelection(String)
        case bothCaretAndSelection(String)

        var description: String {
            switch self {
            case .unbalancedSelection(let s):
                return "unbalanced selection markers in \(EditOp.quote(s))"
            case .bothCaretAndSelection(let s):
                return "both a caret and a selection marker in \(EditOp.quote(s))"
            }
        }
    }

    static func parse(_ source: String, markers: Scenario.Markers) throws -> MarkedText {
        var text = source
        var caret: Int?
        var start: Int?
        var end: Int?

        func take(_ marker: String) -> Int? {
            guard let r = text.range(of: marker) else { return nil }
            let offset = text.utf16.distance(from: text.utf16.startIndex, to: r.lowerBound.samePosition(in: text.utf16)!)
            text.removeSubrange(r)
            return offset
        }

        start = take(markers.selectionStart)
        end = take(markers.selectionEnd)
        caret = take(markers.caret)

        if (start == nil) != (end == nil) {
            throw Failure.unbalancedSelection(source)
        }
        if caret != nil, start != nil {
            throw Failure.bothCaretAndSelection(source)
        }
        if let s = start, let e = end, e < s {
            throw Failure.unbalancedSelection(source)
        }
        return MarkedText(clean: text, caret: caret, selectionStart: start, selectionEnd: end)
    }

    /// Re-insert markers into `clean` at the given offsets — used to render
    /// an actual document in the same shape as the expected one, so a
    /// failure message diffs like-for-like.
    static func render(_ clean: String,
                       selection: NSRange,
                       markers: Scenario.Markers) -> String {
        let ns = clean as NSString
        let loc = max(0, min(selection.location, ns.length))
        let len = max(0, min(selection.length, ns.length - loc))
        if len == 0 {
            return ns.substring(to: loc) + markers.caret + ns.substring(from: loc)
        }
        return ns.substring(to: loc)
            + markers.selectionStart
            + ns.substring(with: NSRange(location: loc, length: len))
            + markers.selectionEnd
            + ns.substring(from: loc + len)
    }
}

enum ScenarioCodec {
    static func decode(_ data: Data) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: data)
    }

    static func encode(_ scenario: Scenario) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(scenario)
    }

    /// Every `*.json` under `root`, sorted by name so test ordering is
    /// stable across machines.
    static func loadAll(under root: URL) -> [(url: URL, scenario: Scenario)] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        var out: [(URL, Scenario)] = []
        for case let url as URL in walker where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let scenario = try? decode(data) else { continue }
            out.append((url, scenario))
        }
        return out.sorted { $0.1.name < $1.1.name }
    }
}
