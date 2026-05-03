import Foundation
import SwiftUI
import MarginaliaView

extension Marginalia {

    public typealias Action = EditorAction

    /// One slot in the toolbar.
    public enum ToolbarItem {
        case action(Action)
        case divider
        case spacer
        case custom(id: String, label: String, systemImage: String, shortcut: KeyboardShortcut? = nil, topLevel: Bool = false, action: () -> Void)
    }

    /// One slot in the status bar.
    public enum StatusItem: Sendable {
        case words
        case characters
        case cursor
        case dialect
    }

    /// Item appended to the underlying text view's right-click / context menu.
    /// Lets callers add app-specific actions (e.g. "Hide Format Bar") so
    /// the choice appears even when the user right-clicks inside the text,
    /// where the SwiftUI `.contextMenu` modifier is shadowed by the native
    /// text view's own contextual menu.
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

    /// Aggregate configuration. Defaults match the SimpleMDE-style toolbar.
    public struct Configuration {
        public var toolbar: [ToolbarItem]
        public var statusItems: [StatusItem]
        public var contextMenuItems: [ContextMenuItem]
        /// How the editor sizes itself within its SwiftUI parent. Defaults
        /// to `.fitsContent` — the editor's height tracks its content.
        /// Use `.fillContainer` for a fixed-height pane that scrolls
        /// internally.
        public var sizing: EditorSizing
        /// In `.fitsContent` mode, the editor starts at this height even
        /// when empty, then grows as content gets taller. Has no effect in
        /// `.fillContainer` mode.
        public var minHeight: CGFloat

        public init(
            toolbar: [ToolbarItem] = Configuration.defaultToolbar,
            statusItems: [StatusItem] = [],
            contextMenuItems: [ContextMenuItem] = [],
            sizing: EditorSizing = .fitsContent,
            minHeight: CGFloat = 96
        ) {
            self.toolbar = toolbar
            self.statusItems = statusItems
            self.contextMenuItems = contextMenuItems
            self.sizing = sizing
            self.minHeight = minHeight
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
            .action(.horizontalRule)
        ]
    }
}

public extension Array where Element == Marginalia.ToolbarItem {
    func replacing(_ action: Marginalia.Action, with replacement: Marginalia.ToolbarItem) -> [Marginalia.ToolbarItem] {
        map { item in
            if case .action(let existing) = item, existing == action {
                return replacement
            }
            return item
        }
    }
}
