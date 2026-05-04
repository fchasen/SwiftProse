import SwiftUI
import SwiftProse

struct ContentView: View {
    @Binding var document: MarkdownDocument
    @State private var controller: EditorController?
    private static let codeHighlighter: CodeBlockHighlighter? = DemoCodeHighlighter.make()

    var body: some View {
        SwiftProseEditor(text: $document.text)
            .configuration(.init(
                toolbar: [],
                statusItems: [],
                sizing: .fillContainer
            ))
            .codeBlockHighlighter(Self.codeHighlighter)
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
            Menu {
                Button { perform(.heading(level: 1)) } label: {
                    Label("Heading 1", systemImage: "1.square")
                }
                Button { perform(.heading(level: 2)) } label: {
                    Label("Heading 2", systemImage: "2.square")
                }
                Button { perform(.heading(level: 3)) } label: {
                    Label("Heading 3", systemImage: "3.square")
                }
                Divider()
                Button { perform(.unorderedList) } label: {
                    Label("Bullet List", systemImage: "list.bullet")
                }
                Button { perform(.orderedList) } label: {
                    Label("Numbered List", systemImage: "list.number")
                }
                Button { perform(.taskList) } label: {
                    Label("Task List", systemImage: "checklist")
                }
                Button { perform(.blockquote) } label: {
                    Label("Blockquote", systemImage: "text.quote")
                }
                Divider()
                Button { perform(.codeSpan) } label: {
                    Label("Inline Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { perform(.codeBlock) } label: {
                    Label("Code Block", systemImage: "curlybraces")
                }
                Button { perform(.horizontalRule) } label: {
                    Label("Horizontal Rule", systemImage: "minus")
                }
            } label: {
                Label("Format", systemImage: "textformat")
            }
            .accessibilityIdentifier("format-menu")
            .disabled(controller == nil)
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
        .disabled(controller == nil)
    }

    private func perform(_ action: EditorAction) {
        guard let controller else { return }
        _ = controller.perform(action)
    }
}

#Preview {
    ContentView(document: .constant(MarkdownDocument()))
}
