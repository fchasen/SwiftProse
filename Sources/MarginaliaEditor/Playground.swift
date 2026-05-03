import Foundation
import SwiftUI
import MarginaliaSyntax
import MarginaliaView

/// A debug surface for poking at a `Marginalia` editor: the editor itself,
/// a fixture picker, and an inspector that shows the parser/highlighter state.
///
/// Embed in a host app's debug menu, or instantiate from a `#Preview` to
/// validate visual regressions while iterating. **Not part of the editor's
/// production UX surface.**
public struct MarginaliaPlayground: View {
    @State private var text: String = MarginaliaPlayground.fixtures[0].source
    @State private var fixture: Int = 0
    @State private var dialect: Dialect = .commonMark
    @State private var showInspector: Bool = true

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                fixturePicker
                Marginalia(text: $text)
                    .dialect(dialect)
                    .frame(minHeight: 320)
            }
            .padding(12)
            if showInspector {
                Divider()
                MarginaliaInspector(source: text, dialect: dialect)
                    .frame(width: 320)
            }
        }
        .toolbar {
            ToolbarItem {
                Button(showInspector ? "Hide inspector" : "Show inspector") {
                    showInspector.toggle()
                }
            }
        }
    }

    private var fixturePicker: some View {
        HStack {
            Picker("Fixture", selection: $fixture) {
                ForEach(MarginaliaPlayground.fixtures.indices, id: \.self) { i in
                    Text(MarginaliaPlayground.fixtures[i].name).tag(i)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: fixture) { _, idx in
                text = MarginaliaPlayground.fixtures[idx].source
            }
            Picker("Dialect", selection: $dialect) {
                Text("CommonMark").tag(Dialect.commonMark)
                Text("Remarkup").tag(Dialect.remarkup)
            }
            .pickerStyle(.segmented)
        }
    }

    public struct Fixture: Identifiable {
        public let id = UUID()
        public let name: String
        public let source: String
    }

    public static let fixtures: [Fixture] = [
        Fixture(name: "Kitchen sink", source: kitchenSinkSource),
        Fixture(name: "Empty", source: ""),
        Fixture(name: "Long blockquote", source: longBlockquoteSource),
        Fixture(name: "Nested list", source: nestedListSource),
        Fixture(name: "Remarkup snippet", source: remarkupSnippetSource)
    ]

    private static let kitchenSinkSource = """
    # Heading 1

    ## Heading 2

    Paragraph with **bold** and *italic* and `code`. Visit
    [Mozilla](https://mozilla.org) for more.

    - Bullet item one
    - Bullet item two

    1. Numbered first
    2. Numbered second

    - [ ] Open task
    - [x] Done task

    > A blockquote.

    ```swift
    let answer = 42
    ```

    ---

    Trailing paragraph.
    """

    private static let longBlockquoteSource = """
    > This is a quote that spans
    > several lines and exists to
    > validate caret-aware focus
    > mode and the blockquote
    > sidebar bar across many
    > vertical pixels.
    """

    private static let nestedListSource = """
    - one
      - one a
      - one b
        - one b i
    - two
      1. nested ordered
      2. another
    """

    private static let remarkupSnippetSource = """
    See D12345 and T999 for context.

    NOTE: this uses //italic// and **bold**.

    {F1234} ships in the next deploy. cc @alice.
    """
}

/// Inspector pane: shows the current source size, parsed block regions,
/// markup ranges, and hidden ranges for whatever's in the editor.
struct MarginaliaInspector: View {
    let source: String
    let dialect: Dialect

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Source") {
                    statsLine("UTF-16 length", "\((source as NSString).length)")
                    statsLine("UTF-8 bytes", "\(source.utf8.count)")
                    statsLine("Lines", "\(source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count)")
                    statsLine("Words", "\(source.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count)")
                }

                section("Block regions") {
                    ForEach(blockRegions, id: \.self) { line in
                        Text(line).font(.caption.monospaced())
                    }
                }

                section("Highlight runs") {
                    ForEach(highlightLines.indices, id: \.self) { i in
                        Text(highlightLines[i]).font(.caption.monospaced())
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold().smallCaps()).foregroundStyle(.secondary)
            content()
        }
    }

    private func statsLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
    }

    private var blockRegions: [String] {
        guard let parser = try? MarkdownParser(grammar: .block),
              let tree = parser.parse(source),
              let root = tree.rootNode else { return [] }
        return BlockClassifier.classify(rootNode: root, mapping: parser.mapping).map {
            "\($0.range.location)…\($0.range.location + $0.range.length): \(describe($0.kind))"
        }
    }

    private var highlightLines: [String] {
        guard let p = try? MarkdownParser(grammar: .block),
              let tree = p.parse(source),
              let root = tree.rootNode,
              let highlighter = try? HighlightApplier() else { return [] }
        return highlighter.highlights(rootNode: root, in: tree, mapping: p.mapping, grammar: .block)
            .prefix(40)
            .map { "\($0.range.location)…\($0.range.location + $0.range.length): \($0.tag.rawValue)" }
    }

    private func describe(_ kind: BlockKind) -> String {
        switch kind {
        case .paragraph: return "paragraph"
        case .heading(let l): return "h\(l)"
        case .setextHeading(let l): return "setext h\(l)"
        case .fencedCode(let lang): return "fenced(\(lang ?? "?"))"
        case .indentedCode: return "indented"
        case .blockquote(let d): return "quote@\(d)"
        case .orderedList: return "ol"
        case .unorderedList: return "ul"
        case .taskList: return "tasks"
        case .horizontalRule: return "hr"
        case .htmlBlock: return "html"
        case .linkReferenceDefinition: return "linkdef"
        case .pipeTable: return "table"
        }
    }
}

#Preview("Marginalia playground") {
    MarginaliaPlayground()
        .frame(width: 1000, height: 600)
}
