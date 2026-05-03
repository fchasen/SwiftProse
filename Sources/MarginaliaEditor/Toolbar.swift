import Foundation
import SwiftUI
import MarginaliaSyntax
import MarginaliaView

struct MarginaliaToolbar: View {
    let items: [Marginalia.ToolbarItem]
    let perform: (Marginalia.Action) -> Void

    var body: some View {
        let groups = makeGroups(from: items)
        let row = HStack(spacing: 8) {
            ForEach(groups.indices, id: \.self) { i in
                groupView(groups[i])
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        #if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) {
            row
                .padding(.vertical, 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        #else
        row
        #endif
    }

    @ViewBuilder
    private func groupView(_ group: ToolbarGroup) -> some View {
        switch group {
        case .spacer:
            Spacer()
        case .items(let items):
            ControlGroup {
                ForEach(items.indices, id: \.self) { i in
                    button(for: items[i])
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func button(for item: Marginalia.ToolbarItem) -> some View {
        switch item {
        case .action(.heading(let level)):
            ToolbarLabelButton(
                label: "H\(level)",
                help: help(for: .heading(level: level)),
                shortcut: shortcut(for: .heading(level: level)),
                action: { perform(.heading(level: level)) }
            )
        case .action(let action):
            ToolbarActionButton(
                systemImage: label(for: action),
                help: help(for: action),
                shortcut: shortcut(for: action),
                action: { perform(action) }
            )
        case let .custom(_, label, symbol, shortcut, _, customPerform):
            ToolbarActionButton(
                systemImage: symbol,
                help: label,
                shortcut: shortcut,
                action: customPerform
            )
        case .divider, .spacer:
            EmptyView()
        }
    }

    private func label(for action: Marginalia.Action) -> String {
        switch action {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .heading(let level): return "h\(level).square"
        case .unorderedList: return "list.bullet"
        case .orderedList: return "list.number"
        case .taskList: return "checklist"
        case .blockquote: return "text.quote"
        case .codeSpan: return "chevron.left.slash.chevron.right"
        case .codeBlock: return "curlybraces"
        case .link: return "link"
        case .horizontalRule: return "minus"
        case .indent: return "increase.indent"
        case .outdent: return "decrease.indent"
        }
    }

    private func help(for action: Marginalia.Action) -> String {
        switch action {
        case .bold: return "Bold (⌘B)"
        case .italic: return "Italic (⌘I)"
        case .strikethrough: return "Strikethrough"
        case .heading(let level): return "Heading \(level)"
        case .unorderedList: return "Bullet list"
        case .orderedList: return "Numbered list"
        case .taskList: return "Task list"
        case .blockquote: return "Blockquote"
        case .codeSpan: return "Inline code"
        case .codeBlock: return "Code block"
        case .link: return "Link (⌘K)"
        case .horizontalRule: return "Horizontal rule"
        case .indent: return "Indent (⌘])"
        case .outdent: return "Outdent (⌘[)"
        }
    }

    /// SwiftUI `.keyboardShortcut` is window-scoped, so attaching one to a
    /// toolbar button broadcasts the shortcut to every Marginalia in the
    /// scene. Keyboard shortcuts are handled inside the focused text view's
    /// `keyDown` (mac) and `keyCommands` (iOS) instead. Toolbar buttons
    /// activate the action they're bound to without an explicit shortcut.
    private func shortcut(for action: Marginalia.Action) -> KeyboardShortcut? {
        nil
    }
}

/// Splits the toolbar list into runs separated by `.divider` (which becomes a
/// group break) and `.spacer` (which becomes a flexible spacer). Each run of
/// actions becomes one `ControlGroup` in the rendered toolbar so the buttons
/// read as related clusters rather than a single flat row.
private enum ToolbarGroup {
    case items([Marginalia.ToolbarItem])
    case spacer
}

private func makeGroups(from items: [Marginalia.ToolbarItem]) -> [ToolbarGroup] {
    var groups: [ToolbarGroup] = []
    var current: [Marginalia.ToolbarItem] = []

    func flush() {
        if !current.isEmpty {
            groups.append(.items(current))
            current.removeAll()
        }
    }

    for item in items {
        switch item {
        case .divider:
            flush()
        case .spacer:
            flush()
            groups.append(.spacer)
        default:
            current.append(item)
        }
    }
    flush()
    return groups
}

private struct ToolbarActionButton: View {
    let systemImage: String
    let help: String
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: ToolbarButtonMetrics.width, height: ToolbarButtonMetrics.height)
        }
        .help(help)
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

private struct ToolbarLabelButton: View {
    let label: String
    let help: String
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var labelSize: CGFloat = 13

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: labelSize, weight: .semibold))
                .frame(width: ToolbarButtonMetrics.width, height: ToolbarButtonMetrics.height)
        }
        .help(help)
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

private enum ToolbarButtonMetrics {
    #if os(iOS)
    static let width: CGFloat = 36
    static let height: CGFloat = 32
    #else
    static let width: CGFloat = 28
    static let height: CGFloat = 24
    #endif
}

private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

enum MarginaliaToolbarActions {
    static func perform(
        _ action: Marginalia.Action,
        controller: EditorController,
        text: Binding<String>
    ) {
        controller.perform(action)
    }
}
