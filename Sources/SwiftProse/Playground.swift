import Foundation
import SwiftUI
import SwiftProseSyntax
import SwiftProseView

/// A debug surface for poking at a `SwiftProseEditor`: the editor itself,
/// a fixture picker, and an inspector that shows the loaded storage vocabulary.
///
/// Embed in a host app's debug menu, or instantiate from a `#Preview` to
/// validate visual regressions while iterating. **Not part of the editor's
/// production UX surface.**
public struct ProsePlayground: View {
    @State private var text: String = ProsePlayground.fixtures[0].source
    @State private var fixture: Int = 0
    @State private var showInspector: Bool = true

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                fixturePicker
                SwiftProseEditor(text: $text)
                    .frame(minHeight: 320)
            }
            .padding(12)
            if showInspector {
                Divider()
                ProseInspector(source: text)
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
        Picker("Fixture", selection: $fixture) {
            ForEach(ProsePlayground.fixtures.indices, id: \.self) { i in
                Text(ProsePlayground.fixtures[i].name).tag(i)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: fixture) { _, idx in
            text = ProsePlayground.fixtures[idx].source
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
        Fixture(name: "Nested list", source: nestedListSource)
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
}

/// Inspector pane: shows the current source size, the loaded block per
/// paragraph, and inline intent runs for whatever's in the editor.
struct ProseInspector: View {
    let source: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Source") {
                    statsLine("UTF-16 length", "\((source as NSString).length)")
                    statsLine("UTF-8 bytes", "\(source.utf8.count)")
                    statsLine("Lines", "\(source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count)")
                    statsLine("Words", "\(source.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count)")
                }

                section("Blocks") {
                    ForEach(blockRegions, id: \.self) { line in
                        Text(line).font(.caption.monospaced())
                    }
                }

                section("Inline runs") {
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

    private var storage: NSAttributedString { MarkdownLoader().load(source) }

    private var blockRegions: [String] {
        let storage = storage
        return storage.markdownParagraphRanges().map { range in
            "\(range.location)…\(NSMaxRange(range)): \(describe(storage.markdownBlock(at: range.location)))"
        }
    }

    private var highlightLines: [String] {
        let storage = storage
        var lines: [String] = []
        storage.enumerateAttribute(.markdownInlineIntent, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let intent = MarkdownInlineIntent(attributeValue: value) ?? []
            guard !intent.isEmpty else { return }
            lines.append("\(range.location)…\(NSMaxRange(range)): \(describe(intent))")
        }
        return Array(lines.prefix(40))
    }

    private func describe(_ block: MarkdownBlock?) -> String {
        guard let block else { return "none" }
        var parts: [String]
        switch block.leaf {
        case .paragraph: parts = ["paragraph"]
        case .heading(let level): parts = ["h\(level)"]
        case .code(let language, _, _): parts = ["code(\(language ?? "?"))"]
        case .thematicBreak: parts = ["hr"]
        case .tableRow(_, _, let isHeader): parts = [isHeader ? "table header" : "table row"]
        case .html: parts = ["html"]
        }
        for container in block.containers {
            switch container {
            case .quote: parts.append("quote")
            case .listItem: parts.append("list")
            }
        }
        if let task = block.task { parts.append(task.isChecked ? "task:checked" : "task:unchecked") }
        if block.isContinuation { parts.append("cont") }
        return parts.joined(separator: " ")
    }

    private func describe(_ intent: MarkdownInlineIntent) -> String {
        var names: [String] = []
        if intent.contains(.stronglyEmphasized) { names.append("strong") }
        if intent.contains(.emphasized) { names.append("emphasis") }
        if intent.contains(.code) { names.append("code") }
        if intent.contains(.strikethrough) { names.append("strikethrough") }
        return names.isEmpty ? "intent(\(intent.rawValue))" : names.joined(separator: " ")
    }
}

#Preview("SwiftProseEditor playground") {
    ProsePlayground()
        .frame(width: 1000, height: 600)
}
