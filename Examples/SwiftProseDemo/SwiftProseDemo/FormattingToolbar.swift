import SwiftUI
import SwiftProse

/// The demo's formatting toolbar. Shared by the document window and the
/// harness window so the XCUITest layer drives the same buttons a user does.
struct FormattingToolbar: ToolbarContent {
    let controller: EditorController?

    @ToolbarContentBuilder
    var body: some ToolbarContent {
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
                Divider()
                Button { perform(.insertTable(rows: 2, columns: 3)) } label: {
                    Label("Insert Table", systemImage: "tablecells")
                }
                Button { perform(.insertTableRowBelow) } label: {
                    Label("Insert Row Below", systemImage: "rectangle.stack.badge.plus")
                }
                Button { perform(.insertTableColumnAfter) } label: {
                    Label("Insert Column Right", systemImage: "rectangle.split.3x1")
                }
                Button { perform(.deleteTableRow) } label: {
                    Label("Delete Row", systemImage: "rectangle.stack.badge.minus")
                }
                Button { perform(.deleteTableColumn) } label: {
                    Label("Delete Column", systemImage: "rectangle.split.3x1")
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
