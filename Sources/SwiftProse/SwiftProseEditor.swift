import Foundation
import SwiftUI
@_exported import SwiftProseSyntax
@_exported import SwiftProseRendering
@_exported import SwiftProseView

#if canImport(AppKit) && os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct SwiftProseEditor: View {
    @Binding public var text: String

    @Environment(\.proseConfiguration) private var configuration
    @Environment(\.proseTheme) private var theme
    @Environment(\.proseInlineContentProvider) private var inlineProvider
    @Environment(\.proseControllerReady) private var onControllerReady
    @Environment(\.proseCodeBlockHighlighter) private var codeBlockHighlighter

    @AppStorage("swiftprose.toolbarVisible") private var toolbarVisible = true
    @StateObject private var hosting = ProseHosting()

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if toolbarVisible, !configuration.toolbar.isEmpty || !configuration.statusItems.isEmpty {
                HStack(spacing: 12) {
                    if !configuration.toolbar.isEmpty {
                        ProseToolbar(
                            items: configuration.toolbar,
                            perform: { action in
                                guard let controller = hosting.controller else { return }
                                ProseToolbarActions.perform(
                                    action,
                                    controller: controller,
                                    text: $text
                                )
                            },
                            canPerform: { action in
                                hosting.controller?.canPerform(action) ?? true
                            }
                        )
                    }
                    if !configuration.statusItems.isEmpty {
                        Spacer()
                        ProseStatusBar(
                            items: configuration.statusItems,
                            text: text,
                            selection: hosting.selection
                        )
                    }
                }
                .padding(6)
            }
            editorBody
        }
        .onAppear {
            hosting.ensureController(
                initialText: text,
                theme: theme,
                codeBlockHighlighter: codeBlockHighlighter
            )
            if let controller = hosting.controller {
                if controller.markdown() != text { controller.setMarkdown(text) }
                hosting.bindSelection(from: controller)
                onControllerReady?(controller)
            }
        }
        .onChange(of: theme) { _, newTheme in
            hosting.controller?.theme = newTheme
        }
        .sheet(item: $hosting.activeTableCellEdit) { request in
            TableCellEditSheet(request: request) { newText in
                _ = hosting.controller?.applyTableCellEdit(
                    tableRange: request.tableRange,
                    row: request.row,
                    column: request.column,
                    text: newText
                )
                hosting.activeTableCellEdit = nil
            } cancel: {
                hosting.activeTableCellEdit = nil
            }
        }
    }

    @ViewBuilder
    private var editorBody: some View {
        if let controller = hosting.controller {
            #if os(macOS)
            ProseTextViewMac(
                controller: controller,
                text: $text,
                sizing: configuration.sizing,
                minHeight: configuration.minHeight,
                contextMenuItems: macContextMenuItems()
            )
            .modifier(SizingFrame(sizing: configuration.sizing))
            #else
            ProseTextViewIOS(
                controller: controller,
                text: $text,
                sizing: configuration.sizing,
                minHeight: configuration.minHeight,
                editMenuBuilder: makeIOSEditMenuBuilder(controller: controller)
            )
            .modifier(SizingFrame(sizing: configuration.sizing))
            #endif
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: configuration.minHeight)
        }
    }

    #if os(macOS)
    private func macContextMenuItems() -> [ProseContextMenuItem] {
        var items: [ProseContextMenuItem] = []
        if !configuration.toolbar.isEmpty {
            let visible = toolbarVisible
            items.append(ProseContextMenuItem(
                title: "Show Toolbar",
                systemImage: "richtext.page",
                isOn: visible,
                action: { toolbarVisible.toggle() }
            ))
        }
        items.append(contentsOf: configuration.contextMenuItems.map { item in
            ProseContextMenuItem(
                title: item.title,
                systemImage: item.systemImage,
                isOn: item.isOn,
                action: item.action
            )
        })
        return items
    }
    #endif

    #if os(iOS)
    private func makeIOSEditMenuBuilder(controller: EditorController) -> ProseTextViewIOS.EditMenuBuilder? {
        let toolbar = configuration.toolbar
        guard !toolbar.isEmpty else { return nil }
        let textBinding = $text
        return { _, suggested in
            var topLevel: [UIAction] = []
            var sections: [UIMenuElement] = []
            var current: [UIAction] = []
            func flush() {
                if !current.isEmpty {
                    sections.append(UIMenu(title: "", options: .displayInline, children: current))
                    current.removeAll()
                }
            }
            for item in toolbar {
                switch item {
                case .action(let action):
                    current.append(UIAction(
                        title: editMenuTitle(for: action),
                        image: UIImage(systemName: editMenuSymbol(for: action))
                    ) { _ in
                        ProseToolbarActions.perform(
                            action,
                            controller: controller,
                            text: textBinding
                        )
                    })
                case .custom(_, let label, let symbol, _, let isTopLevel, let custom):
                    let action = UIAction(
                        title: label,
                        image: UIImage(systemName: symbol),
                        handler: { _ in custom() }
                    )
                    if isTopLevel {
                        flush()
                        topLevel.append(action)
                    } else {
                        current.append(action)
                    }
                case .divider, .spacer:
                    flush()
                }
            }
            flush()
            var children: [UIMenuElement] = suggested
            children.append(contentsOf: topLevel)
            if !sections.isEmpty {
                children.append(UIMenu(
                    title: "Format",
                    image: UIImage(systemName: "textformat"),
                    children: sections
                ))
            }
            return UIMenu(children: children)
        }
    }
    #endif
}

#if os(iOS)
private func editMenuTitle(for action: SwiftProseEditor.Action) -> String {
    switch action {
    case .bold: return "Bold"
    case .italic: return "Italic"
    case .strikethrough: return "Strikethrough"
    case .heading(let level): return "Heading \(level)"
    case .unorderedList: return "Bullet List"
    case .orderedList: return "Numbered List"
    case .taskList: return "Task List"
    case .blockquote: return "Quote"
    case .codeSpan: return "Inline Code"
    case .codeBlock: return "Code Block"
    case .link: return "Link"
    case .horizontalRule: return "Horizontal Rule"
    case .indent: return "Indent"
    case .outdent: return "Outdent"
    }
}

private func editMenuSymbol(for action: SwiftProseEditor.Action) -> String {
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
#endif

private struct SizingFrame: ViewModifier {
    let sizing: EditorSizing
    func body(content: Content) -> some View {
        switch sizing {
        case .fitsContent:
            content.frame(maxWidth: .infinity)
        case .fillContainer:
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class ProseHosting: ObservableObject {
    @Published var controller: EditorController?
    @Published var selection: NSRange = NSRange(location: 0, length: 0)
    @Published var activeTableCellEdit: TableCellEditRequest?

    func ensureController(
        initialText: String,
        theme: ProseTheme,
        codeBlockHighlighter: CodeBlockHighlighter? = nil
    ) {
        if controller == nil {
            controller = try? EditorController(
                initialMarkdown: initialText,
                theme: theme,
                codeBlockHighlighter: codeBlockHighlighter
            )
        }
    }

    /// Wire the controller's selection callback to keep `selection` in
    /// sync with the host text view. Idempotent — safe to re-bind across
    /// onAppear cycles.
    func bindSelection(from controller: EditorController) {
        controller.onSelectionChanged = { [weak self] range in
            self?.selection = range
        }
        controller.onTableCellTapped = { [weak self] hit in
            self?.activeTableCellEdit = TableCellEditRequest(
                id: UUID(),
                tableRange: hit.tableRange,
                row: hit.row,
                column: hit.column,
                initialText: hit.cellText
            )
        }
    }
}

/// Identifiable payload backing the `.sheet(item:)` table-cell editor.
/// Each tap creates a new `id` so SwiftUI re-presents the sheet even when
/// the same cell is clicked twice.
struct TableCellEditRequest: Identifiable, Equatable {
    let id: UUID
    let tableRange: NSRange
    let row: Int
    let column: Int
    let initialText: String
}

/// Compact sheet for editing a single pipe-table cell. The text view inside
/// the editor doesn't host editable cells (TextKit 2 has no real table
/// support), so a click on a cell pops this up instead. Save dispatches an
/// `applyTableCellEdit` transaction.
struct TableCellEditSheet: View {
    let request: TableCellEditRequest
    let save: (String) -> Void
    let cancel: () -> Void

    @State private var text: String

    init(request: TableCellEditRequest, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.request = request
        self.save = save
        self.cancel = cancel
        self._text = State(initialValue: request.initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headerLabel)
                .font(.headline)
            TextField("Cell text", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 180)
    }

    private var headerLabel: String {
        let rowLabel = request.row == -1 ? "Header" : "Row \(request.row + 1)"
        return "\(rowLabel) · Column \(request.column + 1)"
    }
}
