@_exported import SwiftProseSyntax
@_exported import SwiftProseRendering
@_exported import SwiftProseView
import Foundation
import SwiftUI
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

public struct SwiftProseEditor: View {
    @Binding public var text: String

    @Environment(\.proseConfiguration) private var configuration
    @Environment(\.proseTheme) private var theme
    @Environment(\.proseInlineContentProvider) private var inlineProvider
    @Environment(\.proseInlineContentRules) private var inlineContentRules
    @Environment(\.proseCodeBlockHighlighter) private var codeBlockHighlighter
    @Environment(\.proseControllerReady) private var onEditorReady
    @Environment(\.proseHandleReady) private var onHandleReady
    @Environment(\.proseEditorMode) private var modeBinding
    @Environment(\.isEnabled) private var isEnabled

    @AppStorage(SwiftProseEditor.toolbarVisibleKey) private var toolbarVisible = true
    @State private var hosting = EditorHosting()
    @State private var tableSheet: TableSheetRequest?
    @State private var localMode: EditorMode = .rich

    public static let toolbarVisibleKey = "swiftprose.toolbarVisible"

    public init(text: Binding<String>) {
        self._text = text
    }

    static func showsToolbar(for configuration: Configuration) -> Bool {
        !configuration.toolbar.isEmpty
    }

    static func showsHeaderRow(for configuration: Configuration) -> Bool {
        showsToolbar(for: configuration) || !configuration.statusItems.isEmpty
    }

    static func effectiveIsEditable(for configuration: Configuration, isEnabled: Bool) -> Bool {
        configuration.isEditable && isEnabled
    }

    private var effectiveIsEditable: Bool {
        Self.effectiveIsEditable(for: configuration, isEnabled: isEnabled)
    }

    private var mode: EditorMode {
        modeBinding?.wrappedValue ?? localMode
    }

    private func toggleMode() {
        let wasFocused = hosting.handle?.isFocused == true
        let next = mode.toggled
        hosting.setMode(next)
        if let modeBinding {
            modeBinding.wrappedValue = next
        } else {
            localMode = next
        }
        if wasFocused { hosting.requestFocus() }
    }

    public var body: some View {
        let mode = self.mode
        let controller = hosting.ensureController(
            markdown: text,
            theme: theme,
            inlineContentRules: inlineContentRules,
            inlineContentProvider: inlineProvider,
            codeBlockHighlighter: codeBlockHighlighter,
            allowsCheckboxToggle: configuration.allowsCheckboxToggle,
            mode: mode
        )
        hosting.trackedActions = configuration.toolbar.editorActions
        hosting.tracksSelection = !configuration.statusItems.isEmpty
        hosting.setMode(mode)
        return VStack(alignment: .leading, spacing: 0) {
            if toolbarVisible, Self.showsHeaderRow(for: configuration) {
                HStack(spacing: 12) {
                    if Self.showsToolbar(for: configuration) {
                        EditorToolbar(
                            items: configuration.toolbar.resolvingEditorActions(
                                isAvailable: { hosting.canPerform($0) },
                                perform: { [weak hosting] action in hosting?.perform(action) }
                            ),
                            perform: { hosting.perform($0) },
                            canPerform: { hosting.canPerform($0) },
                            isActive: { hosting.isActive($0) },
                            isEnabled: effectiveIsEditable,
                            mode: mode,
                            onToggleMode: { toggleMode() }
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
                .padding(configuration.toolbarPadding)
            }
            switch mode {
            case .rich:
                editorBody(controller: controller)
            case .source:
                if let source = hosting.sourceController {
                    sourceBody(controller: source)
                }
            }
        }
        .sheet(item: $tableSheet) { request in
            TableStructureEditor(
                model: request.model,
                onCancel: { tableSheet = nil },
                onDone: { model in
                    tableSheet = nil
                    controller.applyTableStructure(model)
                }
            )
        }
        .onAppear {
            controller.onEditTableStructure = { model in
                tableSheet = TableSheetRequest(model: model)
            }
            hosting.applyInlineContent(rules: inlineContentRules, provider: inlineProvider)
            hosting.apply(codeBlockHighlighter: codeBlockHighlighter)
            hosting.refreshToolbarState()
            onEditorReady?(controller)
            if let handle = hosting.handle { onHandleReady?(handle) }
        }
        .onChange(of: theme) { _, newTheme in
            hosting.apply(theme: newTheme)
        }
        .onChange(of: codeBlockHighlighter.map(ObjectIdentifier.init)) { _, _ in
            hosting.apply(codeBlockHighlighter: codeBlockHighlighter)
        }
        .onChange(of: configuration.allowsCheckboxToggle) { _, value in
            controller.allowsCheckboxToggle = value
        }
        .onChange(of: effectiveIsEditable) { _, _ in
            hosting.scheduleToolbarRefresh()
        }
        .onChange(of: mode) { _, _ in
            hosting.scheduleToolbarRefresh()
        }
        .onChange(of: configuration.toolbar.editorActions.map(\.stableID)) { _, _ in
            hosting.scheduleToolbarRefresh()
        }
        .onChange(of: inlineContentRules.map(\.id)) { _, _ in
            hosting.applyInlineContent(rules: inlineContentRules, provider: inlineProvider)
        }
    }

    @ViewBuilder
    private func editorBody(controller: EditorController) -> some View {
        #if os(macOS)
        ProseTextViewMac(
            controller: controller,
            text: $text,
            sizing: configuration.sizing,
            minHeight: configuration.minHeight,
            contextMenuItems: contextMenuItems(),
            spellChecking: configuration.spellChecking,
            isEditable: effectiveIsEditable,
            onSubmit: configuration.onSubmit
        )
        .modifier(SizingFrame(sizing: configuration.sizing))
        #else
        ProseTextViewIOS(
            controller: controller,
            text: $text,
            sizing: configuration.sizing,
            minHeight: configuration.minHeight,
            editMenuBuilder: editMenuBuilder(controller: controller),
            spellChecking: configuration.spellChecking,
            isEditable: effectiveIsEditable,
            onSubmit: configuration.onSubmit
        )
        .modifier(SizingFrame(sizing: configuration.sizing))
        #endif
    }

    @ViewBuilder
    private func sourceBody(controller: SourceEditorController) -> some View {
        #if os(macOS)
        ProseSourceTextViewMac(
            controller: controller,
            text: $text,
            sizing: configuration.sizing,
            minHeight: configuration.minHeight,
            contextMenuItems: contextMenuItems(),
            spellChecking: configuration.sourceSpellChecking,
            isEditable: effectiveIsEditable,
            onSubmit: configuration.onSubmit
        )
        .modifier(SizingFrame(sizing: configuration.sizing))
        #else
        ProseSourceTextViewIOS(
            controller: controller,
            text: $text,
            sizing: configuration.sizing,
            minHeight: configuration.minHeight,
            editMenuBuilder: sourceEditMenuBuilder(controller: controller),
            spellChecking: configuration.sourceSpellChecking,
            isEditable: effectiveIsEditable,
            onSubmit: configuration.onSubmit
        )
        .modifier(SizingFrame(sizing: configuration.sizing))
        #endif
    }

    #if os(macOS)
    private func contextMenuItems() -> [ProseContextMenuItem] {
        var items: [ProseContextMenuItem] = []
        if Self.showsHeaderRow(for: configuration) {
            let visible = toolbarVisible
            items.append(ProseContextMenuItem(
                title: "Show Toolbar",
                systemImage: "richtext.page",
                isOn: visible,
                action: { toolbarVisible.toggle() }
            ))
        }
        items.append(contentsOf: configuration.contextMenuItems.map {
            ProseContextMenuItem(title: $0.title, systemImage: $0.systemImage, isOn: $0.isOn, action: $0.action)
        })
        return items
    }
    #endif

    #if os(iOS)
    private func editMenuBuilder(controller: EditorController) -> ProseTextViewIOS.EditMenuBuilder? {
        let toolbar = configuration.toolbar
        guard !toolbar.isEmpty else { return nil }
        let toggle: () -> Void = { toggleMode() }
        return { [weak controller] _, suggested in
            guard let controller else { return UIMenu(children: suggested) }
            return Self.editMenu(toolbar: toolbar, suggested: suggested, controller: controller, onToggleMode: toggle)
        }
    }

    private func sourceEditMenuBuilder(controller: SourceEditorController) -> ProseTextViewIOS.EditMenuBuilder? {
        let toolbar = configuration.toolbar
        guard !toolbar.isEmpty else { return nil }
        let toggle: () -> Void = { toggleMode() }
        return { [weak controller] _, suggested in
            guard let controller else { return UIMenu(children: suggested) }
            return Self.editMenu(
                toolbar: toolbar,
                suggested: suggested,
                canPerform: { [weak controller] in controller?.canPerform($0) ?? false },
                isActive: { [weak controller] in controller?.isActive($0) ?? false },
                perform: { [weak controller] in controller?.perform($0) },
                mode: .source,
                onToggleMode: toggle
            )
        }
    }

    @MainActor
    static func editMenu(
        toolbar: [ToolbarItem],
        suggested: [UIMenuElement],
        controller: EditorController,
        onToggleMode: (() -> Void)? = nil
    ) -> UIMenu {
        editMenu(
            toolbar: toolbar,
            suggested: suggested,
            canPerform: { [weak controller] in controller?.canPerform($0) ?? false },
            isActive: { [weak controller] in controller?.isActive($0) ?? false },
            perform: { [weak controller] action in
                guard let controller else { return }
                EditorToolbarActions.perform(action, controller: controller)
            },
            mode: .rich,
            onToggleMode: onToggleMode
        )
    }

    @MainActor
    static func editMenu(
        toolbar: [ToolbarItem],
        suggested: [UIMenuElement],
        canPerform: @escaping (EditorAction) -> Bool,
        isActive: @escaping (EditorAction) -> Bool,
        perform: @escaping (EditorAction) -> Void,
        mode: EditorMode,
        onToggleMode: (() -> Void)?
    ) -> UIMenu {
        var topLevel: [UIMenuElement] = []
        var sections: [UIMenuElement] = []
        var current: [UIMenuElement] = []
        func flush() {
            if !current.isEmpty {
                sections.append(UIMenu(title: "", options: .displayInline, children: current))
                current.removeAll()
            }
        }
        func actionElement(_ action: EditorAction, title: String, image: String?) -> UIAction {
            UIAction(
                title: title,
                image: image.flatMap { UIImage(systemName: $0) },
                attributes: canPerform(action) ? [] : .disabled,
                state: isActive(action) ? .on : .off
            ) { _ in perform(action) }
        }
        for item in toolbar {
            switch item {
            case .action(let action):
                current.append(actionElement(action, title: action.title, image: action.systemImage))
            case .custom(_, let label, let symbol, _, let isTopLevel, let custom):
                let element = UIAction(title: label, image: UIImage(systemName: symbol)) { _ in custom() }
                if isTopLevel {
                    flush()
                    topLevel.append(element)
                } else {
                    current.append(element)
                }
            case .menu(let id, _, _, _, _) where id == Self.tableMenuID && mode == .rich:
                continue
            case .menu(_, let label, let symbol, let isTopLevel, let entries):
                let children: [UIMenuElement] = entries.compactMap { entry in
                    if let action = entry.editorAction {
                        guard mode == .rich || canPerform(action) else { return nil }
                        return actionElement(action, title: entry.title, image: entry.systemImage)
                    }
                    return UIAction(
                        title: entry.title,
                        image: entry.systemImage.flatMap { UIImage(systemName: $0) }
                    ) { _ in entry.action() }
                }
                guard !children.isEmpty else { continue }
                let submenu = UIMenu(title: label, image: UIImage(systemName: symbol), children: children)
                if isTopLevel {
                    flush()
                    topLevel.append(submenu)
                } else {
                    current.append(submenu)
                }
            case .modeToggle:
                guard let onToggleMode else { continue }
                flush()
                topLevel.append(UIAction(
                    title: Self.modeToggleTitle(for: mode),
                    image: UIImage(systemName: Self.modeToggleSystemImage(for: mode))
                ) { _ in onToggleMode() })
            case .divider, .spacer:
                flush()
            }
        }
        flush()
        var children = suggested
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
    #endif
}

struct TableSheetRequest: Identifiable {
    let id = UUID()
    let model: TableStructureModel
}

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
