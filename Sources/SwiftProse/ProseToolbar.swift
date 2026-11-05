import SwiftProseSyntax
import SwiftProseRendering
import SwiftProseView
import Foundation
import SwiftUI

public struct ProseToolbar: View {
    public var items: [SwiftProseEditor.ToolbarItem]
    public var perform: (SwiftProseEditor.Action) -> Void
    public var canPerform: (SwiftProseEditor.Action) -> Bool
    public var isActive: (SwiftProseEditor.Action) -> Bool
    public var isEnabled: Bool
    public var mode: EditorMode
    public var onToggleMode: (() -> Void)?

    public init(
        items: [SwiftProseEditor.ToolbarItem],
        perform: @escaping (SwiftProseEditor.Action) -> Void,
        canPerform: @escaping (SwiftProseEditor.Action) -> Bool = { _ in true },
        isActive: @escaping (SwiftProseEditor.Action) -> Bool = { _ in false },
        isEnabled: Bool = true,
        mode: EditorMode = .rich,
        onToggleMode: (() -> Void)? = nil
    ) {
        self.items = items
        self.perform = perform
        self.canPerform = canPerform
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.mode = mode
        self.onToggleMode = onToggleMode
    }

    public var body: some View {
        EditorToolbar(
            items: items.resolvingEditorActions(isAvailable: canPerform, perform: perform),
            perform: perform,
            canPerform: canPerform,
            isActive: isActive,
            isEnabled: isEnabled,
            mode: mode,
            onToggleMode: onToggleMode
        )
    }
}
