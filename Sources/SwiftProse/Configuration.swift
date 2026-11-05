import SwiftProseSyntax
import SwiftProseRendering
import SwiftProseView
import Foundation
import SwiftUI

extension SwiftProseEditor {
    public typealias Action = EditorAction

    public enum ToolbarItem {
        case action(Action)
        case divider
        case spacer
        case custom(id: String, label: String, systemImage: String, shortcut: KeyboardShortcut? = nil, topLevel: Bool = false, action: () -> Void)
        case menu(id: String, label: String, systemImage: String, topLevel: Bool = false, entries: [MenuEntry])
        case modeToggle
    }

    public static func modeToggleTitle(for mode: EditorMode) -> String {
        switch mode {
        case .rich: "Markdown Source"
        case .source: "Rich Text"
        }
    }

    public static func modeToggleSystemImage(for mode: EditorMode) -> String {
        switch mode {
        case .rich: "chevron.left.forwardslash.chevron.right"
        case .source: "doc.richtext"
        }
    }

    public struct MenuEntry {
        public var id: String
        public var title: String
        public var systemImage: String?
        public var action: () -> Void
        public var editorAction: EditorAction?

        public init(
            id: String,
            title: String,
            systemImage: String? = nil,
            action: @escaping () -> Void
        ) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.action = action
            self.editorAction = nil
        }

        public init(editorAction: EditorAction) {
            self.id = editorAction.stableID
            self.title = editorAction.title
            self.systemImage = editorAction.systemImage
            self.action = {}
            self.editorAction = editorAction
        }
    }

    public static let tableMenuID = "swiftprose.table"

    public static let tableMenu: ToolbarItem = .menu(
        id: tableMenuID,
        label: "Table",
        systemImage: "tablecells",
        entries: ([EditorAction.insertTable(rows: 2, columns: 3)] + EditorAction.tableActions).map(MenuEntry.init(editorAction:))
    )

    public enum StatusItem: Sendable {
        case words
        case characters
        case cursor
    }

    public struct ContextMenuItem {
        public var title: String
        public var systemImage: String?
        public var isOn: Bool
        public var action: () -> Void

        public init(
            title: String,
            systemImage: String? = nil,
            isOn: Bool = false,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.systemImage = systemImage
            self.isOn = isOn
            self.action = action
        }
    }

    public struct Configuration {
        public var toolbar: [ToolbarItem]
        public var statusItems: [StatusItem]
        public var contextMenuItems: [ContextMenuItem]
        public var sizing: EditorSizing
        public var minHeight: CGFloat
        public var spellChecking: ProseSpellChecking
        public var sourceSpellChecking: ProseSpellChecking
        public var isEditable: Bool
        public var allowsCheckboxToggle: Bool
        public var toolbarPadding: EdgeInsets
        public var onSubmit: (() -> Void)?

        public init(
            toolbar: [ToolbarItem] = Configuration.defaultToolbar,
            statusItems: [StatusItem] = [],
            contextMenuItems: [ContextMenuItem] = [],
            sizing: EditorSizing = .fitsContent,
            minHeight: CGFloat = 96,
            spellChecking: ProseSpellChecking = .full,
            sourceSpellChecking: ProseSpellChecking? = nil,
            isEditable: Bool = true,
            allowsCheckboxToggle: Bool = false,
            toolbarPadding: EdgeInsets = EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6),
            onSubmit: (() -> Void)? = nil
        ) {
            self.toolbar = toolbar
            self.statusItems = statusItems
            self.contextMenuItems = contextMenuItems
            self.sizing = sizing
            self.minHeight = minHeight
            self.spellChecking = spellChecking
            self.sourceSpellChecking = sourceSpellChecking ?? spellChecking.withoutAutocorrection
            self.isEditable = isEditable
            self.allowsCheckboxToggle = allowsCheckboxToggle
            self.toolbarPadding = toolbarPadding
            self.onSubmit = onSubmit
        }

        public static let defaultToolbar: [ToolbarItem] = [
            .action(.bold),
            .action(.italic),
            .action(.strikethrough),
            .divider,
            .action(.heading(level: 1)),
            .action(.heading(level: 2)),
            .action(.heading(level: 3)),
            .divider,
            .action(.unorderedList),
            .action(.orderedList),
            .action(.taskList),
            .action(.blockquote),
            .divider,
            .action(.codeSpan),
            .action(.codeBlock),
            .action(.link),
            .action(.horizontalRule),
            .divider,
            SwiftProseEditor.tableMenu,
            .spacer,
            .modeToggle
        ]
    }
}

public extension Array where Element == SwiftProseEditor.ToolbarItem {
    var editorActions: [EditorAction] {
        flatMap { item -> [EditorAction] in
            switch item {
            case .action(let action): return [action]
            case .menu(_, _, _, _, let entries): return entries.compactMap(\.editorAction)
            default: return []
            }
        }
    }

    func resolvingEditorActions(
        isAvailable: (EditorAction) -> Bool = { _ in true },
        perform: @escaping (EditorAction) -> Void
    ) -> [SwiftProseEditor.ToolbarItem] {
        map { item in
            guard case let .menu(id, label, symbol, topLevel, entries) = item,
                  entries.contains(where: { $0.editorAction != nil }) else { return item }
            let resolved = entries.compactMap { entry -> SwiftProseEditor.MenuEntry? in
                guard let action = entry.editorAction else { return entry }
                guard isAvailable(action) else { return nil }
                var copy = entry
                copy.action = { perform(action) }
                return copy
            }
            return .menu(id: id, label: label, systemImage: symbol, topLevel: topLevel, entries: resolved)
        }
    }

    func replacing(_ action: SwiftProseEditor.Action, with replacement: SwiftProseEditor.ToolbarItem) -> [SwiftProseEditor.ToolbarItem] {
        map { item in
            if case .action(let existing) = item, existing == action {
                return replacement
            }
            return item
        }
    }
}
