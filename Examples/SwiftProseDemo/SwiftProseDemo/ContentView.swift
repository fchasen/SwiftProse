import SwiftUI
import SwiftProse

struct ContentView: View {
    @Binding var document: MarkdownDocument
    @State private var controller: EditorController?
    @AppStorage("swiftprose.mode") private var modeRawValue: String = Mode.rich.rawValue

    private var mode: Mode { Mode(rawValue: modeRawValue) ?? .rich }
    private var isSourceMode: Bool { mode == .source }

    var body: some View {
        SwiftProseEditor(text: $document.text)
            .configuration(.init(
                toolbar: [],
                statusItems: [],
                sizing: .fillContainer
            ))
            .onProseControllerReady { controller = $0 }
            .accessibilityIdentifier("prose-editor")
            .toolbar { formattingToolbar }
    }

    @ToolbarContentBuilder
    private var formattingToolbar: some ToolbarContent {
        ToolbarItem { actionButton(.bold, systemImage: "bold", label: "Bold", id: "bold") }
        ToolbarItem { actionButton(.italic, systemImage: "italic", label: "Italic", id: "italic") }
        ToolbarItem { actionButton(.strikethrough, systemImage: "strikethrough", label: "Strikethrough", id: "strikethrough") }
        ToolbarItem { actionButton(.link, systemImage: "link", label: "Link", id: "link") }
        ToolbarItem {
            Button {
                modeRawValue = (isSourceMode ? Mode.rich : .source).rawValue
            } label: {
                Label(
                    isSourceMode ? "Show Rendered" : "Show Source",
                    systemImage: isSourceMode ? "eye" : "doc.plaintext"
                )
            }
            .accessibilityIdentifier("mode-toggle")
        }
        ToolbarItem {
            Menu {
                Button("Heading 1") { perform(.heading(level: 1)) }
                Button("Heading 2") { perform(.heading(level: 2)) }
                Button("Heading 3") { perform(.heading(level: 3)) }
                Divider()
                Button("Bullet List") { perform(.unorderedList) }
                Button("Numbered List") { perform(.orderedList) }
                Button("Task List") { perform(.taskList) }
                Button("Blockquote") { perform(.blockquote) }
                Divider()
                Button("Inline Code") { perform(.codeSpan) }
                Button("Code Block") { perform(.codeBlock) }
                Button("Horizontal Rule") { perform(.horizontalRule) }
            } label: {
                Label("Format", systemImage: "textformat")
            }
            .accessibilityIdentifier("format-menu")
            .disabled(controller == nil || isSourceMode)
        }
    }

    private func actionButton(
        _ action: EditorAction,
        systemImage: String,
        label: String,
        id: String
    ) -> some View {
        Button {
            perform(action)
        } label: {
            Label(label, systemImage: systemImage)
        }
        .accessibilityIdentifier(id)
        .disabled(controller == nil || isSourceMode)
    }

    private func perform(_ action: EditorAction) {
        guard let controller else { return }
        _ = controller.perform(action)
    }
}

#Preview {
    ContentView(document: .constant(MarkdownDocument()))
}
