import Foundation

/// Manifest entry for one checked-in corpus document.
struct CorpusEntry: Codable, Equatable {
    /// File name under `Fixtures/corpus/`.
    var file: String
    /// Where it came from — a URL, or `hand-written` / `generated`.
    var source: String
    /// Pinned commit for a fetched file, so `make-corpus.sh` is reproducible.
    var commit: String?
    var license: String
    /// Bytes, as checked in. A mismatch means the file was re-fetched
    /// without updating the manifest.
    var bytes: Int?
    /// Feature tags a scenario or fuzz profile can select on.
    var features: [String] = []
}

struct CorpusManifest: Codable, Equatable {
    var entries: [CorpusEntry]
}

/// Fixture access. Hosted tests run inside the app, so `Bundle.main` is
/// the host app bundle and the folder reference in its Resources phase is
/// what both see.
enum Fixtures {

    /// Overridable so the CLI can point at the source tree instead of the
    /// built bundle.
    static var overrideRoot: URL?

    static var root: URL? {
        if let overrideRoot { return overrideRoot }
        if let url = Bundle.main.url(forResource: "Fixtures", withExtension: nil) { return url }
        return sourceRoot
    }

    /// The checked-in `Fixtures` folder, derived from this file's compiled
    /// path. `root` normally resolves to the *copy* inside the built app
    /// bundle; anything a test writes back — the round-trip ledger, a
    /// recorded scenario — has to land here instead.
    static var sourceRoot: URL? {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Harness
            .deletingLastPathComponent()   // SwiftProseDemo
            .appendingPathComponent("Fixtures")
        return FileManager.default.fileExists(atPath: here.path) ? here : nil
    }

    static var corpusRoot: URL? { root?.appendingPathComponent("corpus") }
    static var scenariosRoot: URL? { root?.appendingPathComponent("scenarios") }

    /// Gitignored, soak-only documents (Moby Dick and friends).
    static var externalCorpusRoot: URL? {
        root?.deletingLastPathComponent().appendingPathComponent("Fixtures-external")
    }

    static var manifest: CorpusManifest? {
        guard let url = corpusRoot?.appendingPathComponent("corpus.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CorpusManifest.self, from: data)
    }

    /// Corpus documents, smallest first so a failing fuzz run reports the
    /// cheapest reproduction it found.
    static func corpus(features: Set<String> = []) -> [(name: String, markdown: String)] {
        guard let corpusRoot else { return builtIn }
        var out: [(String, String)] = []
        let entries = manifest?.entries ?? []
        let names: [String]
        if entries.isEmpty {
            names = ((try? FileManager.default.contentsOfDirectory(atPath: corpusRoot.path)) ?? [])
                .filter { $0.hasSuffix(".md") }
                .sorted()
        } else {
            names = entries
                .filter { features.isEmpty || !features.isDisjoint(with: Set($0.features)) }
                .map(\.file)
        }
        for name in names {
            let url = corpusRoot.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, text))
        }
        return out.isEmpty ? builtIn : out.sorted { $0.1.count < $1.1.count }
    }

    static func document(named name: String) -> String? {
        corpus().first { $0.name == name }?.markdown
            ?? builtIn.first { $0.name == name }?.markdown
    }

    /// Always available, even before `make-corpus.sh` has run: enough
    /// structure for a smoke fuzz to be meaningful.
    static let builtIn: [(name: String, markdown: String)] = [
        ("empty", ""),
        ("paragraph", "One paragraph with **bold**, *em*, `code` and a [link](https://example.com).\n"),
        ("kitchen-sink", """
        # Heading 1

        ## Heading 2

        Paragraph with **bold** and *italic* and `code`. Visit
        [Mozilla](https://mozilla.org) for more.

        - Bullet item one
        - Bullet item two
          - Nested item

        1. Numbered first
        2. Numbered second

        - [ ] unchecked task
        - [x] checked task

        > A quote
        > continued across lines

        ```swift
        let value = 42
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        ---

        Final paragraph.
        """)
    ]
}
