import SwiftUI
@_spi(Harness) import SwiftProse

/// The window the app presents under test, or with `--harness`: one
/// editor, one inspector, no `DocumentGroup`. Deterministic — no Cmd-N, no
/// restoration race, no second window.
struct HarnessView: View {
    @StateObject private var registry = HarnessRegistry.shared
    @State private var text: String = ""
    @State private var showInspector = true
    private static let codeHighlighter: CodeBlockHighlighter? = DemoCodeHighlighter.make()

    var body: some View {
        HStack(spacing: 0) {
            SwiftProseEditor(text: $text)
                .configuration(.init(toolbar: [], statusItems: [], sizing: .fillContainer))
                .codeBlockHighlighter(Self.codeHighlighter)
                .onProseControllerReady { registry.attach($0) }
                .accessibilityIdentifier("prose-editor")
                .frame(minWidth: 420)
            if showInspector {
                Divider()
                inspector.frame(width: 320)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem {
                Button(showInspector ? "Hide inspector" : "Show inspector") {
                    showInspector.toggle()
                }
            }
        }
        .onAppear { HarnessLaunchActions.startIfRequested() }
    }

    /// The same actions the document window's toolbar carries, with the
    /// same accessibility identifiers, as plain buttons in the view body.
    /// A SwiftUI `.toolbar` needs a window that owns one; the CLI hosts
    /// this view in a bare `NSWindow`, and attaching a toolbar there stalls
    /// the first render — which stalls every harness run.
    private var formattingBar: some View {
        HStack(spacing: 6) {
            actionButton(.bold, "bold", "B")
            actionButton(.italic, "italic", "I")
            actionButton(.strikethrough, "strikethrough", "S")
            actionButton(.link(url: "https://example.com", label: nil), "link", "link")
            Menu("Format") {
                Button("Heading 1") { perform(.heading(level: 1)) }
                Button("Heading 2") { perform(.heading(level: 2)) }
                Button("Paragraph") { perform(.heading(level: 0)) }
                Divider()
                Button("Bullet List") { perform(.unorderedList) }
                Button("Numbered List") { perform(.orderedList) }
                Button("Task List") { perform(.taskList) }
                Button("Blockquote") { perform(.blockquote) }
                Divider()
                Button("Inline Code") { perform(.codeSpan) }
                Button("Code Block") { perform(.codeBlock) }
                Button("Horizontal Rule") { perform(.horizontalRule) }
                Divider()
                Button("Insert Table") { perform(.insertTable(rows: 2, columns: 3)) }
            }
            .accessibilityIdentifier("format-menu")
            .frame(width: 90)
            Spacer()
        }
        .disabled(registry.controller == nil)
    }

    private func actionButton(_ action: EditorAction, _ id: String, _ label: String) -> some View {
        Button(label) { perform(action) }
            .accessibilityIdentifier(id)
    }

    private func perform(_ action: EditorAction) {
        guard let controller = registry.controller else { return }
        _ = controller.perform(action)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            formattingBar
            LabeledContent("status", value: registry.status)
                .accessibilityIdentifier("harness-status")
            LabeledContent("op", value: "\(registry.progress)")
            if let controller = registry.controller {
                LabeledContent("length", value: "\(controller.textStorage.length)")
                LabeledContent("blocks", value: "\(controller.document.root.children.count)")
                LabeledContent("selection", value: "\(controller.currentSelection)")
                LabeledContent("undo / redo",
                               value: "\(controller.undoDepth) / \(controller.redoDepth)")
            }
            if !registry.classCoverage.isEmpty {
                Text("edit classes")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(registry.classCoverage.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: "\(registry.classCoverage[key] ?? 0)")
                        .font(.caption)
                }
            }
            Divider()
            Text("markdown")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(registry.markdownMirror)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // XCUITests can only read accessibility values, so the mirror
            // is also published as one.
            .accessibilityIdentifier("markdown-mirror")
            .accessibilityValue(registry.markdownMirror)
            if registry.paused {
                Button("Resume") { registry.paused = false }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Kicks off whatever `--harness <mode>` asked for, once the editor is up.
enum HarnessLaunchActions {
    private static var started = false

    @MainActor
    static func startIfRequested() {
        guard !started else { return }
        guard let mode = HarnessLaunch.mode, mode == .fuzz || mode == .replay else { return }
        started = true
        #if os(macOS)
        HarnessCLI.scheduleRun(mode: mode)
        #endif
    }
}
